package agent

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
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
	Publish(prepared PreparedWorkspace, request WorkspaceRequest, workerProtocolResult map[string]any) error
}

const maxWorkerProtocolPayloadBytes = 1024 * 1024

type Worker struct {
	AgentName    string
	Client       ControlPlane
	Executor     CommandExecutor
	Materializer WorkspacePreparer
	Now          func() time.Time
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

	now := w.now()
	startedAt := now.Format(time.RFC3339)
	runRequest, prepared, workspaceDescriptor, err := w.prepareRequest(*request)
	if err != nil {
		result, idle, submitErr := w.submitFailure(*request, workspaceDescriptor, startedAt, fmt.Sprintf("A3 agent workspace preparation failed: %v\n", err))
		cleanupErr := w.cleanupPrepared(*request, prepared)
		if submitErr != nil {
			return result, idle, submitErr
		}
		return result, idle, cleanupErr
	}

	execution := w.executor().Execute(runRequest)
	finishedAt := w.now().Format(time.RFC3339)
	logUpload, err := w.upload("combined-log", safeID(request.JobID+"-combined-log"), "diagnostic", "text/plain", execution.CombinedLog)
	if err != nil {
		return nil, false, err
	}
	artifactUploads, workerProtocolResult, err := w.uploadArtifactsAndWorkerResult(runRequest)
	if err != nil {
		return nil, false, err
	}
	if prepared != nil && request.WorkspaceRequest != nil {
		if err := w.publishPrepared(*prepared, *request.WorkspaceRequest, workerProtocolResult); err != nil {
			if refreshErr := RefreshWorkspaceEvidence(*prepared); refreshErr == nil {
				workspaceDescriptor = requestedWorkspaceDescriptor(runRequest, prepared.SlotDescriptors)
			}
			result := postExecutionFailureResult(*request, workspaceDescriptor, startedAt, finishedAt, logUpload, artifactUploads, "A3 agent workspace publish failed", "agent_workspace_publish", err)
			submitErr := w.Client.SubmitResult(result)
			cleanupErr := w.cleanupPrepared(*request, prepared)
			if submitErr != nil {
				return &result, false, submitErr
			}
			return &result, false, cleanupErr
		}
	}
	if prepared != nil {
		if err := RefreshWorkspaceEvidence(*prepared); err != nil {
			return nil, false, err
		}
		workspaceDescriptor = requestedWorkspaceDescriptor(runRequest, prepared.SlotDescriptors)
	}

	result := JobResult{
		JobID:                request.JobID,
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
	submitErr := w.Client.SubmitResult(result)
	cleanupErr := w.cleanupPrepared(runRequest, prepared)
	if submitErr != nil {
		return &result, false, submitErr
	}
	return &result, false, cleanupErr
}

func (w Worker) publishPrepared(prepared PreparedWorkspace, request WorkspaceRequest, workerProtocolResult map[string]any) error {
	if publisher, ok := w.Materializer.(WorkspacePublisher); ok {
		return publisher.Publish(prepared, request, workerProtocolResult)
	}
	return PublishWorkspaceChanges(prepared, request, workerProtocolResult)
}

func postExecutionFailureResult(request JobRequest, descriptor WorkspaceDescriptor, startedAt, finishedAt string, logUpload ArtifactUpload, artifactUploads []ArtifactUpload, summary, failingCommand string, cause error) JobResult {
	code := 1
	return JobResult{
		JobID:               request.JobID,
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

func (w Worker) prepareRequest(request JobRequest) (JobRequest, *PreparedWorkspace, WorkspaceDescriptor, error) {
	if request.WorkspaceRequest == nil {
		return request, nil, legacyWorkspaceDescriptor(request), nil
	}
	if w.Materializer == nil {
		return request, nil, requestedWorkspaceDescriptor(request, nil), fmt.Errorf("workspace materializer is not configured")
	}
	prepared, err := w.Materializer.Prepare(*request.WorkspaceRequest)
	if err != nil {
		return request, nil, requestedWorkspaceDescriptor(request, nil), err
	}
	runRequest := request
	runRequest.WorkingDir = prepared.Root
	runRequest.Env = workerProtocolEnv(request.Env, prepared.Root, request.WorkerProtocolRequest != nil)
	if err := writeWorkerProtocolRequest(prepared.Root, request.WorkerProtocolRequest); err != nil {
		return request, &prepared, requestedWorkspaceDescriptor(request, prepared.SlotDescriptors), err
	}
	descriptor := requestedWorkspaceDescriptor(request, prepared.SlotDescriptors)
	return runRequest, &prepared, descriptor, nil
}

func (w Worker) submitFailure(request JobRequest, descriptor WorkspaceDescriptor, startedAt string, message string) (*JobResult, bool, error) {
	code := 1
	finishedAt := w.now().Format(time.RFC3339)
	logUpload, err := w.upload("combined-log", safeID(request.JobID+"-combined-log"), "diagnostic", "text/plain", []byte(message))
	if err != nil {
		return nil, false, err
	}
	result := JobResult{
		JobID:               request.JobID,
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
	return &result, false, w.Client.SubmitResult(result)
}

func (w Worker) cleanupPrepared(request JobRequest, prepared *PreparedWorkspace) error {
	if prepared == nil || request.WorkspaceRequest == nil {
		return nil
	}
	if request.WorkspaceRequest.CleanupPolicy != "cleanup_after_job" {
		return nil
	}
	return w.Materializer.Cleanup(*prepared)
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
			upload, err := w.upload(role, id, retentionClass, rule["media_type"], content)
			if err != nil {
				return nil, nil, err
			}
			uploads = append(uploads, upload)
		}
	}
	return uploads, workerProtocolResult, nil
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
	upload, err := w.upload("worker-result", safeID(request.JobID+"-worker-result"), "evidence", "application/json", content)
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

func (w Worker) upload(role, artifactID, retentionClass, mediaType string, content []byte) (ArtifactUpload, error) {
	sum := sha256.Sum256(content)
	upload := ArtifactUpload{
		ArtifactID:     artifactID,
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

func (w Worker) now() time.Time {
	if w.Now != nil {
		return w.Now()
	}
	return time.Now().UTC()
}

func legacyWorkspaceDescriptor(request JobRequest) WorkspaceDescriptor {
	return WorkspaceDescriptor{
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
	return WorkspaceDescriptor{
		WorkspaceKind:    workspaceKind,
		RuntimeProfile:   request.RuntimeProfile,
		WorkspaceID:      workspaceID,
		SourceDescriptor: request.SourceDescriptor,
		SlotDescriptors:  slots,
	}
}

func writeWorkerProtocolRequest(workspaceRoot string, payload map[string]any) error {
	if payload == nil {
		return nil
	}
	if err := os.MkdirAll(filepath.Join(workspaceRoot, ".a3"), 0o755); err != nil {
		return err
	}
	content, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	if len(content) > maxWorkerProtocolPayloadBytes {
		return fmt.Errorf("worker protocol request exceeds %d bytes", maxWorkerProtocolPayloadBytes)
	}
	return os.WriteFile(workerRequestPath(workspaceRoot), append(content, '\n'), 0o600)
}

func workerProtocolEnv(base map[string]string, workspaceRoot string, hasWorkerProtocolRequest bool) map[string]string {
	env := map[string]string{}
	for key, value := range base {
		env[key] = value
	}
	env["A3_WORKSPACE_ROOT"] = workspaceRoot
	env["A3_WORKER_RESULT_PATH"] = workerResultPath(workspaceRoot)
	if hasWorkerProtocolRequest {
		env["A3_WORKER_REQUEST_PATH"] = workerRequestPath(workspaceRoot)
	}
	return env
}

func workerRequestPath(workspaceRoot string) string {
	return filepath.Join(workspaceRoot, ".a3", "worker-request.json")
}

func workerResultPath(workspaceRoot string) string {
	return filepath.Join(workspaceRoot, ".a3", "worker-result.json")
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
