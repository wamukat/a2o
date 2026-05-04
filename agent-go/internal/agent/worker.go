package agent

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

type CommandExecutor interface {
	Execute(request JobRequest) ExecutionResult
}

type WorkspacePreparer interface {
	Prepare(request WorkspaceRequest) (PreparedWorkspace, error)
	Cleanup(prepared PreparedWorkspace) error
}

type WorkspacePublisher interface {
	Publish(prepared PreparedWorkspace, request WorkspaceRequest, workerProtocolResult map[string]any, commandSucceeded bool) error
}

type WorkspaceMerger interface {
	Merge(request MergeRequest) (WorkspaceDescriptor, ExecutionResult)
}

type MergeRecoveryFinalizer interface {
	RecoverMerge(request MergeRecoveryRequest) (WorkspaceDescriptor, ExecutionResult)
}

const maxWorkerProtocolPayloadBytes = 1024 * 1024
const defaultJobHeartbeatInterval = 30 * time.Second

type Worker struct {
	AgentName         string
	Client            ControlPlane
	Executor          CommandExecutor
	Materializer      WorkspacePreparer
	Now               func() time.Time
	HeartbeatInterval time.Duration
	HeartbeatErrorLog io.Writer
	EventLog          io.Writer
}

type LoopOptions struct {
	PollInterval  time.Duration
	MaxIterations int
	Sleep         func(time.Duration)
}

type LoopResult struct {
	Iterations int
	Jobs       int
	Idle       int
	LastResult *JobResult
}

func (w Worker) RunLoop(options LoopOptions) (LoopResult, error) {
	result := LoopResult{}
	pollInterval := options.PollInterval
	if pollInterval <= 0 {
		pollInterval = time.Second
	}
	sleep := options.Sleep
	if sleep == nil {
		sleep = time.Sleep
	}
	for options.MaxIterations <= 0 || result.Iterations < options.MaxIterations {
		jobResult, idle, err := w.RunOnce()
		result.Iterations++
		if err != nil {
			return result, err
		}
		if idle {
			result.Idle++
			sleep(pollInterval)
			continue
		}
		result.Jobs++
		result.LastResult = jobResult
	}
	return result, nil
}

func (w Worker) RunOnce() (*JobResult, bool, error) {
	request, err := w.Client.ClaimNext(w.AgentName)
	if err != nil {
		return nil, false, err
	}
	if request == nil {
		return nil, true, nil
	}

	w.logJobEvent(*request, "claimed", nil)
	now := w.now()
	startedAt := now.Format(time.RFC3339)
	stopHeartbeat := w.startHeartbeat(request.JobID)
	defer stopHeartbeat()
	if request.MergeRequest != nil {
		return w.runMergeJob(*request, startedAt)
	}
	if request.MergeRecoveryRequest != nil {
		return w.runMergeRecoveryJob(*request, startedAt)
	}
	w.logJobEvent(*request, "materialize_start", nil)
	runRequest, prepared, workspaceDescriptor, err := w.prepareRequest(*request)
	if err != nil {
		w.logJobEvent(*request, "materialize_error", map[string]any{"error": err.Error()})
		result, idle, submitErr := w.submitFailure(*request, workspaceDescriptor, startedAt, fmt.Sprintf("A2O agent workspace preparation failed: %v\n", err))
		w.logJobEvent(*request, "cleanup_start", nil)
		cleanupErr := w.cleanupPrepared(*request, prepared)
		if cleanupErr != nil {
			w.logJobEvent(*request, "cleanup_error", map[string]any{"error": cleanupErr.Error()})
		} else {
			w.logJobEvent(*request, "cleanup_done", nil)
		}
		if submitErr != nil {
			return result, idle, submitErr
		}
		return result, idle, cleanupErr
	}
	w.logJobEvent(runRequest, "materialize_done", map[string]any{"workspace_id": workspaceDescriptor.WorkspaceID})

	w.logJobEvent(runRequest, "command_start", nil)
	execution := w.executor().Execute(runRequest)
	finishedAt := w.now().Format(time.RFC3339)
	w.logJobEvent(runRequest, "command_done", map[string]any{"status": execution.Status, "exit_code": execution.ExitCode})
	w.logJobEvent(runRequest, "upload_start", nil)
	logUpload, err := w.upload(*request, "combined-log", safeID(request.JobID+"-combined-log"), "analysis", "text/plain", execution.CombinedLog)
	if err != nil {
		w.logJobEvent(*request, "upload_error", map[string]any{"role": "combined-log", "error": err.Error()})
		return nil, false, err
	}
	artifactUploads, workerProtocolResult, err := w.uploadArtifactsAndWorkerResult(runRequest)
	if err != nil {
		w.logJobEvent(runRequest, "upload_error", map[string]any{"error": err.Error()})
		return nil, false, err
	}
	if workerProtocolResult == nil {
		workerProtocolResult = commandOutputWorkerProtocolResult(runRequest, execution)
	}
	if prepared != nil && request.WorkspaceRequest != nil && workerProtocolResult != nil && workerProtocolResult["success"] == true && execution.Status == "succeeded" {
		hookReport, hookErr := RunCompletionHooks(*prepared, *request.WorkspaceRequest)
		if hookReport.Ran() {
			if upload, err := w.uploadCompletionHookReport(runRequest, hookReport); err != nil {
				w.logJobEvent(runRequest, "upload_error", map[string]any{"role": "completion-hooks", "error": err.Error()})
				return nil, false, err
			} else {
				artifactUploads = append(artifactUploads, upload)
			}
		}
		if hookErr != nil {
			if publishErr := PublishCompletionHookAttempt(*prepared, *request.WorkspaceRequest); publishErr != nil {
				if refreshErr := RefreshWorkspaceEvidence(*prepared); refreshErr == nil {
					workspaceDescriptor = requestedWorkspaceDescriptor(runRequest, prepared.SlotDescriptors)
				}
				w.logJobEvent(runRequest, "publish_error", map[string]any{"operation": "completion_hook_attempt", "error": publishErr.Error()})
				result := postExecutionFailureResult(*request, workspaceDescriptor, startedAt, finishedAt, logUpload, artifactUploads, "A2O agent completion hook attempt publish failed", "completion_hook_attempt_publish", publishErr)
				w.logJobEvent(runRequest, "submit_start", map[string]any{"status": result.Status})
				stopHeartbeat()
				submitErr := w.Client.SubmitResult(result)
				if submitErr != nil {
					w.logJobEvent(runRequest, "submit_error", map[string]any{"error": submitErr.Error()})
				} else {
					w.logJobEvent(runRequest, "submit_done", map[string]any{"status": result.Status})
				}
				w.logJobEvent(runRequest, "cleanup_start", nil)
				cleanupErr := w.cleanupPrepared(*request, prepared)
				if cleanupErr != nil {
					w.logJobEvent(runRequest, "cleanup_error", map[string]any{"error": cleanupErr.Error()})
				} else {
					w.logJobEvent(runRequest, "cleanup_done", nil)
				}
				if submitErr != nil {
					return &result, false, submitErr
				}
				return &result, false, cleanupErr
			}
			if refreshErr := RefreshWorkspaceEvidence(*prepared); refreshErr == nil {
				workspaceDescriptor = requestedWorkspaceDescriptor(runRequest, prepared.SlotDescriptors)
			}
			w.logJobEvent(runRequest, "completion_hook_failed", map[string]any{"error": hookErr.Error()})
			result := postCompletionHookReworkResult(*request, workspaceDescriptor, startedAt, finishedAt, logUpload, artifactUploads, hookReport, hookErr)
			w.logJobEvent(runRequest, "submit_start", map[string]any{"status": result.Status})
			stopHeartbeat()
			submitErr := w.Client.SubmitResult(result)
			if submitErr != nil {
				w.logJobEvent(runRequest, "submit_error", map[string]any{"error": submitErr.Error()})
			} else {
				w.logJobEvent(runRequest, "submit_done", map[string]any{"status": result.Status})
			}
			w.logJobEvent(runRequest, "cleanup_start", nil)
			cleanupErr := w.cleanupPrepared(*request, prepared)
			if cleanupErr != nil {
				w.logJobEvent(runRequest, "cleanup_error", map[string]any{"error": cleanupErr.Error()})
			} else {
				w.logJobEvent(runRequest, "cleanup_done", nil)
			}
			if submitErr != nil {
				return &result, false, submitErr
			}
			return &result, false, cleanupErr
		}
	}
	if metadataUpload, err := w.uploadExecutionMetadata(*request, execution, startedAt, finishedAt); err != nil {
		w.logJobEvent(*request, "upload_error", map[string]any{"role": "execution-metadata", "error": err.Error()})
		return nil, false, err
	} else if metadataUpload != nil {
		artifactUploads = append(artifactUploads, *metadataUpload)
	}
	if rawLogUpload, err := w.uploadAIRawLog(runRequest); err != nil {
		w.logJobEvent(runRequest, "upload_error", map[string]any{"role": "ai-raw-log", "error": err.Error()})
		return nil, false, err
	} else if rawLogUpload != nil {
		artifactUploads = append(artifactUploads, *rawLogUpload)
	}
	w.logJobEvent(runRequest, "upload_done", map[string]any{"artifact_count": len(artifactUploads) + 1})
	if prepared != nil && request.WorkspaceRequest != nil {
		w.logJobEvent(runRequest, "publish_start", nil)
		if err := w.publishPrepared(*prepared, *request, workerProtocolResult, execution.Status == "succeeded"); err != nil {
			if refreshErr := RefreshWorkspaceEvidence(*prepared); refreshErr == nil {
				workspaceDescriptor = requestedWorkspaceDescriptor(runRequest, prepared.SlotDescriptors)
			}
			w.logJobEvent(runRequest, "publish_error", map[string]any{"error": err.Error()})
			result := postExecutionFailureResult(*request, workspaceDescriptor, startedAt, finishedAt, logUpload, artifactUploads, "A2O agent workspace publish failed", "agent_workspace_publish", err)
			w.logJobEvent(runRequest, "submit_start", map[string]any{"status": result.Status})
			stopHeartbeat()
			submitErr := w.Client.SubmitResult(result)
			if submitErr != nil {
				w.logJobEvent(runRequest, "submit_error", map[string]any{"error": submitErr.Error()})
			} else {
				w.logJobEvent(runRequest, "submit_done", map[string]any{"status": result.Status})
			}
			w.logJobEvent(runRequest, "cleanup_start", nil)
			cleanupErr := w.cleanupPrepared(*request, prepared)
			if cleanupErr != nil {
				w.logJobEvent(runRequest, "cleanup_error", map[string]any{"error": cleanupErr.Error()})
			} else {
				w.logJobEvent(runRequest, "cleanup_done", nil)
			}
			if submitErr != nil {
				return &result, false, submitErr
			}
			return &result, false, cleanupErr
		}
		w.logJobEvent(runRequest, "publish_done", nil)
	}
	if prepared != nil {
		if err := RefreshWorkspaceEvidence(*prepared); err != nil {
			w.logJobEvent(runRequest, "materialize_error", map[string]any{"operation": "refresh_workspace_evidence", "error": err.Error()})
			return nil, false, err
		}
		workspaceDescriptor = requestedWorkspaceDescriptor(runRequest, prepared.SlotDescriptors)
	}

	result := JobResult{
		JobID:                request.JobID,
		ProjectKey:           request.ProjectKey,
		Status:               execution.Status,
		ExitCode:             execution.ExitCode,
		StartedAt:            startedAt,
		FinishedAt:           finishedAt,
		Summary:              fmt.Sprintf("%s %v %s", request.Command, request.Args, execution.Status),
		LogUploads:           []ArtifactUpload{logUpload},
		ArtifactUploads:      artifactUploads,
		WorkspaceDescriptor:  workspaceDescriptor,
		WorkerProtocolResult: workerProtocolResult,
		Heartbeat:            finishedAt,
	}
	w.logJobEvent(runRequest, "submit_start", map[string]any{"status": result.Status})
	stopHeartbeat()
	submitErr := w.Client.SubmitResult(result)
	if submitErr != nil {
		w.logJobEvent(runRequest, "submit_error", map[string]any{"error": submitErr.Error()})
	} else {
		w.logJobEvent(runRequest, "submit_done", map[string]any{"status": result.Status})
	}
	w.logJobEvent(runRequest, "cleanup_start", nil)
	cleanupErr := w.cleanupPrepared(runRequest, prepared)
	if cleanupErr != nil {
		w.logJobEvent(runRequest, "cleanup_error", map[string]any{"error": cleanupErr.Error()})
	} else {
		w.logJobEvent(runRequest, "cleanup_done", nil)
	}
	if submitErr != nil {
		return &result, false, submitErr
	}
	return &result, false, cleanupErr
}

func (w Worker) logJobEvent(request JobRequest, stage string, fields map[string]any) {
	if w.EventLog == nil {
		return
	}
	payload := map[string]any{
		"stage":          stage,
		"job_id":         request.JobID,
		"project_key":    request.ProjectKey,
		"task_ref":       request.TaskRef,
		"run_ref":        request.RunRef,
		"phase":          request.Phase,
		"command_intent": commandIntent(request),
		"workspace_id":   workspaceID(request),
	}
	for key, value := range fields {
		if key == "stage" {
			payload["detail_stage"] = value
			continue
		}
		payload[key] = value
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		fmt.Fprintf(w.EventLog, "a2o_agent_job_event {\"stage\":\"%s\",\"job_id\":\"%s\",\"encoding_error\":\"%s\"}\n", stage, request.JobID, err.Error())
		return
	}
	fmt.Fprintf(w.EventLog, "a2o_agent_job_event %s\n", encoded)
}

func commandIntent(request JobRequest) string {
	if request.WorkerProtocolRequest == nil {
		return ""
	}
	value, _ := request.WorkerProtocolRequest["command_intent"].(string)
	return value
}

func workspaceID(request JobRequest) string {
	if request.WorkspaceRequest == nil {
		return ""
	}
	return request.WorkspaceRequest.WorkspaceID
}

func (w Worker) startHeartbeat(jobID string) func() {
	interval := w.HeartbeatInterval
	if interval <= 0 {
		interval = defaultJobHeartbeatInterval
	}
	done := make(chan struct{})
	send := func() {
		if err := w.Client.Heartbeat(jobID, w.now().Format(time.RFC3339)); err != nil {
			w.logHeartbeatError(jobID, err)
		}
	}
	send()
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				send()
			case <-done:
				return
			}
		}
	}()
	var stopped bool
	return func() {
		if stopped {
			return
		}
		stopped = true
		close(done)
	}
}

func (w Worker) logHeartbeatError(jobID string, err error) {
	if err == nil || w.HeartbeatErrorLog == nil {
		return
	}
	fmt.Fprintf(w.HeartbeatErrorLog, "a2o-agent heartbeat failed job_id=%s error=%v\n", jobID, err)
}

func (w Worker) runMergeJob(request JobRequest, startedAt string) (*JobResult, bool, error) {
	descriptor, execution := w.mergeRequest(request)
	finishedAt := w.now().Format(time.RFC3339)
	descriptor.ProjectKey = request.ProjectKey
	descriptor.RuntimeProfile = request.RuntimeProfile
	descriptor.SourceDescriptor = request.SourceDescriptor
	if descriptor.WorkspaceKind == "" {
		descriptor.WorkspaceKind = request.SourceDescriptor.WorkspaceKind
	}
	logUpload, err := w.upload(request, "combined-log", safeID(request.JobID+"-combined-log"), "analysis", "text/plain", execution.CombinedLog)
	if err != nil {
		return nil, false, err
	}
	artifactUploads := []ArtifactUpload{}
	if metadataUpload, err := w.uploadExecutionMetadata(request, execution, startedAt, finishedAt); err != nil {
		return nil, false, err
	} else if metadataUpload != nil {
		artifactUploads = append(artifactUploads, *metadataUpload)
	}
	result := JobResult{
		JobID:               request.JobID,
		ProjectKey:          request.ProjectKey,
		Status:              execution.Status,
		ExitCode:            execution.ExitCode,
		StartedAt:           startedAt,
		FinishedAt:          finishedAt,
		Summary:             fmt.Sprintf("merge %s", execution.Status),
		LogUploads:          []ArtifactUpload{logUpload},
		ArtifactUploads:     artifactUploads,
		WorkspaceDescriptor: descriptor,
		Heartbeat:           finishedAt,
	}
	submitErr := w.Client.SubmitResult(result)
	if submitErr != nil {
		return &result, false, submitErr
	}
	return &result, false, nil
}

func (w Worker) runMergeRecoveryJob(request JobRequest, startedAt string) (*JobResult, bool, error) {
	descriptor, execution := w.mergeRecoveryRequest(request)
	finishedAt := w.now().Format(time.RFC3339)
	descriptor.ProjectKey = request.ProjectKey
	descriptor.RuntimeProfile = request.RuntimeProfile
	descriptor.SourceDescriptor = request.SourceDescriptor
	if descriptor.WorkspaceKind == "" {
		descriptor.WorkspaceKind = request.SourceDescriptor.WorkspaceKind
	}
	logUpload, err := w.upload(request, "combined-log", safeID(request.JobID+"-combined-log"), "analysis", "text/plain", execution.CombinedLog)
	if err != nil {
		return nil, false, err
	}
	artifactUploads := []ArtifactUpload{}
	if metadataUpload, err := w.uploadExecutionMetadata(request, execution, startedAt, finishedAt); err != nil {
		return nil, false, err
	} else if metadataUpload != nil {
		artifactUploads = append(artifactUploads, *metadataUpload)
	}
	result := JobResult{
		JobID:               request.JobID,
		ProjectKey:          request.ProjectKey,
		Status:              execution.Status,
		ExitCode:            execution.ExitCode,
		StartedAt:           startedAt,
		FinishedAt:          finishedAt,
		Summary:             fmt.Sprintf("merge recovery %s", execution.Status),
		LogUploads:          []ArtifactUpload{logUpload},
		ArtifactUploads:     artifactUploads,
		WorkspaceDescriptor: descriptor,
		Heartbeat:           finishedAt,
	}
	submitErr := w.Client.SubmitResult(result)
	if submitErr != nil {
		return &result, false, submitErr
	}
	return &result, false, nil
}

func (w Worker) mergeRequest(request JobRequest) (WorkspaceDescriptor, ExecutionResult) {
	if merger, ok := w.workspacePreparerForRequest(request).(WorkspaceMerger); ok {
		return merger.Merge(*request.MergeRequest)
	}
	return WorkspaceDescriptor{WorkspaceID: request.MergeRequest.WorkspaceID, SlotDescriptors: map[string]map[string]any{}}, failedMergeExecution(fmt.Errorf("workspace merger is not configured"))
}

func (w Worker) mergeRecoveryRequest(request JobRequest) (WorkspaceDescriptor, ExecutionResult) {
	if finalizer, ok := w.workspacePreparerForRequest(request).(MergeRecoveryFinalizer); ok {
		return finalizer.RecoverMerge(*request.MergeRecoveryRequest)
	}
	return WorkspaceDescriptor{WorkspaceID: request.MergeRecoveryRequest.WorkspaceID, SlotDescriptors: map[string]map[string]any{}}, failedMergeExecution(fmt.Errorf("merge recovery finalizer is not configured"))
}

func (w Worker) publishPrepared(prepared PreparedWorkspace, request JobRequest, workerProtocolResult map[string]any, commandSucceeded bool) error {
	if request.WorkspaceRequest == nil {
		return fmt.Errorf("workspace request is not configured")
	}
	if publisher, ok := w.workspacePreparerForRequest(request).(WorkspacePublisher); ok {
		return publisher.Publish(prepared, *request.WorkspaceRequest, workerProtocolResult, commandSucceeded)
	}
	return PublishWorkspaceChanges(prepared, *request.WorkspaceRequest, workerProtocolResult, commandSucceeded)
}

func postExecutionFailureResult(request JobRequest, descriptor WorkspaceDescriptor, startedAt, finishedAt string, logUpload ArtifactUpload, artifactUploads []ArtifactUpload, summary, failingCommand string, cause error) JobResult {
	code := 1
	return JobResult{
		JobID:               request.JobID,
		ProjectKey:          request.ProjectKey,
		Status:              "failed",
		ExitCode:            &code,
		StartedAt:           startedAt,
		FinishedAt:          finishedAt,
		Summary:             summary,
		LogUploads:          []ArtifactUpload{logUpload},
		ArtifactUploads:     artifactUploads,
		WorkspaceDescriptor: descriptor,
		WorkerProtocolResult: map[string]any{
			"success":         false,
			"failing_command": failingCommand,
			"observed_state":  "failed",
			"error":           cause.Error(),
		},
		Heartbeat: finishedAt,
	}
}

func postCompletionHookReworkResult(request JobRequest, descriptor WorkspaceDescriptor, startedAt, finishedAt string, logUpload ArtifactUpload, artifactUploads []ArtifactUpload, report CompletionHookReport, cause error) JobResult {
	code := 0
	failingCommand := "implementation_completion_hooks"
	observedState := "completion_hook_failed"
	summary := "implementation completion hook requested rework"
	if entry := report.FailingEntry(); entry != nil {
		failingCommand = "implementation_completion_hooks." + entry.Name
		observedState = entry.Reason
		if observedState == "" {
			observedState = "completion_hook_failed"
		}
		summary = fmt.Sprintf("implementation completion hook %s failed for slot %s", entry.Name, entry.Slot)
	}
	diagnostics := map[string]any{
		"completion_hooks":             report,
		"completion_hook_attempt_refs": completionHookAttemptRefs(descriptor),
	}
	return JobResult{
		JobID:               request.JobID,
		ProjectKey:          request.ProjectKey,
		Status:              "succeeded",
		ExitCode:            &code,
		StartedAt:           startedAt,
		FinishedAt:          finishedAt,
		Summary:             summary,
		LogUploads:          []ArtifactUpload{logUpload},
		ArtifactUploads:     artifactUploads,
		WorkspaceDescriptor: descriptor,
		WorkerProtocolResult: map[string]any{
			"task_ref":         request.TaskRef,
			"run_ref":          request.RunRef,
			"phase":            request.Phase,
			"success":          false,
			"summary":          summary,
			"failing_command":  failingCommand,
			"observed_state":   observedState,
			"rework_required":  true,
			"diagnostics":      diagnostics,
			"completion_hooks": report,
			"error":            cause.Error(),
		},
		Heartbeat: finishedAt,
	}
}

func completionHookAttemptRefs(descriptor WorkspaceDescriptor) map[string]string {
	refs := map[string]string{}
	for slotName, slot := range descriptor.SlotDescriptors {
		for _, key := range []string{"publish_after_head", "resolved_head"} {
			value, ok := slot[key].(string)
			if ok && strings.TrimSpace(value) != "" {
				refs[slotName] = value
				break
			}
		}
	}
	return refs
}

func (w Worker) prepareRequest(request JobRequest) (JobRequest, *PreparedWorkspace, WorkspaceDescriptor, error) {
	if request.WorkspaceRequest == nil {
		return request, nil, legacyWorkspaceDescriptor(request), nil
	}
	materializer := w.workspacePreparerForRequest(request)
	if materializer == nil {
		return request, nil, requestedWorkspaceDescriptor(request, nil), fmt.Errorf("workspace materializer is not configured")
	}
	prepared, err := materializer.Prepare(*request.WorkspaceRequest)
	if err != nil {
		return request, nil, requestedWorkspaceDescriptor(request, nil), err
	}
	runRequest := request
	runRequest.WorkingDir = prepared.Root
	runRequest.Env = workerProtocolEnv(requestEnvForAgent(request), prepared.Root, request.WorkerProtocolRequest != nil)
	if err := writeWorkerProtocolRequest(prepared.Root, workerProtocolRequestWithMaterializedSlots(request.WorkerProtocolRequest, prepared.SlotDescriptors)); err != nil {
		return request, &prepared, requestedWorkspaceDescriptor(request, prepared.SlotDescriptors), err
	}
	descriptor := requestedWorkspaceDescriptor(request, prepared.SlotDescriptors)
	return runRequest, &prepared, descriptor, nil
}

func (w Worker) submitFailure(request JobRequest, descriptor WorkspaceDescriptor, startedAt string, message string) (*JobResult, bool, error) {
	code := 1
	finishedAt := w.now().Format(time.RFC3339)
	w.logJobEvent(request, "upload_start", map[string]any{"role": "combined-log", "retention_class": "diagnostic"})
	logUpload, err := w.upload(request, "combined-log", safeID(request.JobID+"-combined-log"), "diagnostic", "text/plain", []byte(message))
	if err != nil {
		w.logJobEvent(request, "upload_error", map[string]any{"role": "combined-log", "error": err.Error()})
		return nil, false, err
	}
	w.logJobEvent(request, "upload_done", map[string]any{"artifact_count": 1})
	result := JobResult{
		JobID:               request.JobID,
		ProjectKey:          request.ProjectKey,
		Status:              "failed",
		ExitCode:            &code,
		StartedAt:           startedAt,
		FinishedAt:          finishedAt,
		Summary:             "workspace preparation failed",
		LogUploads:          []ArtifactUpload{logUpload},
		ArtifactUploads:     []ArtifactUpload{},
		WorkspaceDescriptor: descriptor,
		Heartbeat:           finishedAt,
	}
	w.logJobEvent(request, "submit_start", map[string]any{"status": result.Status})
	submitErr := w.Client.SubmitResult(result)
	if submitErr != nil {
		w.logJobEvent(request, "submit_error", map[string]any{"error": submitErr.Error()})
	} else {
		w.logJobEvent(request, "submit_done", map[string]any{"status": result.Status})
	}
	return &result, false, submitErr
}

func (w Worker) cleanupPrepared(request JobRequest, prepared *PreparedWorkspace) error {
	if prepared == nil || request.WorkspaceRequest == nil {
		return nil
	}
	if request.WorkspaceRequest.CleanupPolicy != "cleanup_after_job" {
		return nil
	}
	materializer := w.workspacePreparerForRequest(request)
	if materializer == nil {
		return fmt.Errorf("workspace materializer is not configured")
	}
	return materializer.Cleanup(*prepared)
}

func (w Worker) uploadArtifactsAndWorkerResult(request JobRequest) ([]ArtifactUpload, map[string]any, error) {
	var uploads []ArtifactUpload
	workerResultUpload, workerProtocolResult, err := w.uploadWorkerProtocolResult(request)
	if err != nil {
		return nil, nil, err
	}
	if workerResultUpload != nil {
		uploads = append(uploads, *workerResultUpload)
	}
	for _, rule := range request.ArtifactRules {
		role := rule["role"]
		retentionClass := rule["retention_class"]
		if retentionClass == "" {
			retentionClass = "evidence"
		}
		paths, err := filepath.Glob(filepath.Join(request.WorkingDir, rule["glob"]))
		if err != nil {
			return nil, nil, err
		}
		sort.Strings(paths)
		for _, path := range paths {
			content, err := os.ReadFile(path)
			if err != nil {
				return nil, nil, err
			}
			id := safeID(fmt.Sprintf("%s-%s-%s", request.JobID, role, filepath.Base(path)))
			upload, err := w.upload(request, role, id, retentionClass, rule["media_type"], content)
			if err != nil {
				return nil, nil, err
			}
			uploads = append(uploads, upload)
		}
	}
	return uploads, workerProtocolResult, nil
}

func commandOutputWorkerProtocolResult(request JobRequest, execution ExecutionResult) map[string]any {
	if request.WorkerProtocolRequest == nil {
		return nil
	}
	intent, _ := request.WorkerProtocolRequest["command_intent"].(string)
	if intent != "notification" && !strings.HasPrefix(intent, "decomposition_") {
		return nil
	}
	return map[string]any{
		"success": execution.Status == "succeeded",
		"summary": fmt.Sprintf("%s %v %s", request.Command, request.Args, execution.Status),
		"diagnostics": map[string]any{
			"stdout": string(execution.Stdout),
			"stderr": string(execution.Stderr),
		},
	}
}

func (w Worker) uploadAIRawLog(request JobRequest) (*ArtifactUpload, error) {
	path := aiRawLogPath(request)
	if strings.TrimSpace(path) == "" {
		return nil, nil
	}
	content, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	upload, err := w.upload(request, "ai-raw-log", safeID(request.JobID+"-ai-raw-log"), "analysis", "text/plain", content)
	if err != nil {
		return nil, err
	}
	return &upload, nil
}

func (w Worker) uploadExecutionMetadata(request JobRequest, execution ExecutionResult, startedAt, finishedAt string) (*ArtifactUpload, error) {
	started, err := time.Parse(time.RFC3339, startedAt)
	if err != nil {
		return nil, nil
	}
	finished, err := time.Parse(time.RFC3339, finishedAt)
	if err != nil {
		return nil, nil
	}
	payload := map[string]any{
		"job_id":           request.JobID,
		"project_key":      request.ProjectKey,
		"task_ref":         request.TaskRef,
		"run_ref":          request.RunRef,
		"phase":            request.Phase,
		"status":           execution.Status,
		"summary":          fmt.Sprintf("%s %v %s", request.Command, request.Args, execution.Status),
		"command":          request.Command,
		"args":             request.Args,
		"started_at":       startedAt,
		"finished_at":      finishedAt,
		"duration_seconds": finished.Sub(started).Seconds(),
		"runtime_profile":  request.RuntimeProfile,
		"source": map[string]any{
			"workspace_kind": request.SourceDescriptor.WorkspaceKind,
			"source_type":    request.SourceDescriptor.SourceType,
			"ref":            request.SourceDescriptor.Ref,
			"task_ref":       request.SourceDescriptor.TaskRef,
		},
	}
	if execution.ExitCode != nil {
		payload["exit_code"] = *execution.ExitCode
	}
	content, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return nil, err
	}
	upload, err := w.upload(request, "execution-metadata", safeID(request.JobID+"-execution-metadata"), "analysis", "application/json", append(content, '\n'))
	if err != nil {
		return nil, err
	}
	return &upload, nil
}

func (w Worker) uploadCompletionHookReport(request JobRequest, report CompletionHookReport) (ArtifactUpload, error) {
	content, err := report.JSON()
	if err != nil {
		return ArtifactUpload{}, err
	}
	return w.upload(request, "completion-hooks", safeID(request.JobID+"-completion-hooks"), "evidence", "application/json", content)
}

func (w Worker) uploadWorkerProtocolResult(request JobRequest) (*ArtifactUpload, map[string]any, error) {
	if request.WorkspaceRequest == nil {
		return nil, nil, nil
	}
	resultPath := workerResultPath(request.WorkingDir)
	content, err := os.ReadFile(resultPath)
	if os.IsNotExist(err) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	upload, err := w.upload(request, "worker-result", safeID(request.JobID+"-worker-result"), "evidence", "application/json", content)
	if err != nil {
		return nil, nil, err
	}
	if len(content) > maxWorkerProtocolPayloadBytes {
		return &upload, nil, nil
	}
	var parsed map[string]any
	if err := json.Unmarshal(content, &parsed); err != nil {
		return &upload, nil, nil
	}
	return &upload, parsed, nil
}

func (w Worker) upload(request JobRequest, role, artifactID, retentionClass, mediaType string, content []byte) (ArtifactUpload, error) {
	sum := sha256.Sum256(content)
	upload := ArtifactUpload{
		ArtifactID:     artifactID,
		ProjectKey:     request.ProjectKey,
		Role:           role,
		Digest:         "sha256:" + hex.EncodeToString(sum[:]),
		ByteSize:       len(content),
		RetentionClass: retentionClass,
		MediaType:      mediaType,
	}
	return w.Client.UploadArtifact(upload, content)
}

func (w Worker) executor() CommandExecutor {
	if w.Executor != nil {
		return w.Executor
	}
	return Executor{}
}

func (w Worker) workspacePreparerForRequest(request JobRequest) WorkspacePreparer {
	if request.AgentEnvironment != nil &&
		request.AgentEnvironment.WorkspaceRoot != "" &&
		len(request.AgentEnvironment.SourcePaths) > 0 {
		return WorkspaceMaterializer{
			WorkspaceRoot: request.AgentEnvironment.WorkspaceRoot,
			SourceAliases: request.AgentEnvironment.SourcePaths,
		}
	}
	return w.Materializer
}

func requestEnvForAgent(request JobRequest) map[string]string {
	env := map[string]string{}
	if request.AgentEnvironment != nil {
		for key, value := range request.AgentEnvironment.Env {
			env[key] = value
		}
	}
	for key, value := range request.Env {
		env[key] = value
	}
	return env
}

func (w Worker) now() time.Time {
	if w.Now != nil {
		return w.Now()
	}
	return time.Now().UTC()
}

func legacyWorkspaceDescriptor(request JobRequest) WorkspaceDescriptor {
	return WorkspaceDescriptor{
		ProjectKey:       request.ProjectKey,
		WorkspaceKind:    request.SourceDescriptor.WorkspaceKind,
		RuntimeProfile:   request.RuntimeProfile,
		WorkspaceID:      safeID(request.RuntimeProfile + "-" + request.JobID),
		SourceDescriptor: request.SourceDescriptor,
		SlotDescriptors: map[string]map[string]any{
			"primary": {
				"runtime_path": absPath(request.WorkingDir),
				"dirty":        nil,
			},
		},
	}
}

func requestedWorkspaceDescriptor(request JobRequest, slots map[string]map[string]any) WorkspaceDescriptor {
	workspaceKind := request.SourceDescriptor.WorkspaceKind
	workspaceID := safeID(request.RuntimeProfile + "-" + request.JobID)
	if request.WorkspaceRequest != nil {
		workspaceKind = request.WorkspaceRequest.WorkspaceKind
		workspaceID = request.WorkspaceRequest.WorkspaceID
	}
	if slots == nil {
		slots = map[string]map[string]any{}
	}
	descriptor := WorkspaceDescriptor{
		ProjectKey:       request.ProjectKey,
		WorkspaceKind:    workspaceKind,
		RuntimeProfile:   request.RuntimeProfile,
		WorkspaceID:      workspaceID,
		SourceDescriptor: request.SourceDescriptor,
		SlotDescriptors:  slots,
	}
	if request.WorkspaceRequest != nil {
		descriptor.Topology = request.WorkspaceRequest.Topology
	}
	return descriptor
}

func writeWorkerProtocolRequest(workspaceRoot string, payload map[string]any) error {
	if payload == nil {
		return nil
	}
	if err := os.MkdirAll(filepath.Join(workspaceRoot, ".a2o"), 0o755); err != nil {
		return err
	}
	content, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return err
	}
	if len(content) > maxWorkerProtocolPayloadBytes {
		return fmt.Errorf("worker protocol request exceeds %d bytes", maxWorkerProtocolPayloadBytes)
	}
	return os.WriteFile(workerRequestPath(workspaceRoot), append(content, '\n'), 0o600)
}

func workerProtocolRequestWithMaterializedSlots(payload map[string]any, slotDescriptors map[string]map[string]any) map[string]any {
	if payload == nil {
		return nil
	}
	enriched := map[string]any{}
	for key, value := range payload {
		enriched[key] = value
	}
	slotPaths := map[string]string{}
	for slotName, descriptor := range slotDescriptors {
		runtimePath, ok := descriptor["runtime_path"].(string)
		if !ok || runtimePath == "" {
			continue
		}
		slotPaths[slotName] = runtimePath
	}
	if len(slotPaths) > 0 {
		enriched["slot_paths"] = slotPaths
	}
	return enriched
}

func workerProtocolEnv(base map[string]string, workspaceRoot string, hasWorkerProtocolRequest bool) map[string]string {
	env := map[string]string{}
	for key, value := range base {
		env[key] = value
	}
	env["A2O_WORKSPACE_ROOT"] = workspaceRoot
	env["A2O_WORKER_RESULT_PATH"] = workerResultPath(workspaceRoot)
	env["AUTOMATION_ISSUE_WORKSPACE"] = workspaceRoot
	if hasWorkerProtocolRequest {
		env["A2O_WORKER_REQUEST_PATH"] = workerRequestPath(workspaceRoot)
	}
	return env
}

func aiRawLogPath(request JobRequest) string {
	root := strings.TrimSpace(request.Env["A2O_AGENT_AI_RAW_LOG_ROOT"])
	if root == "" {
		root = strings.TrimSpace(request.Env["A3_AGENT_AI_RAW_LOG_ROOT"])
	}
	if root == "" {
		root = strings.TrimSpace(os.Getenv("A2O_AGENT_AI_RAW_LOG_ROOT"))
	}
	if root == "" {
		root = strings.TrimSpace(os.Getenv("A3_AGENT_AI_RAW_LOG_ROOT"))
	}
	if root == "" {
		return ""
	}
	return filepath.Join(root, safeID(request.TaskRef), safeID(request.Phase)+".log")
}

func workerRequestPath(workspaceRoot string) string {
	return filepath.Join(workspaceRoot, ".a2o", "worker-request.json")
}

func workerResultPath(workspaceRoot string) string {
	return filepath.Join(workspaceRoot, ".a2o", "worker-result.json")
}

func absPath(path string) string {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return path
	}
	return absolute
}

var unsafeIDPattern = regexp.MustCompile(`[^A-Za-z0-9._:-]`)

func safeID(value string) string {
	return unsafeIDPattern.ReplaceAllString(value, "-")
}
