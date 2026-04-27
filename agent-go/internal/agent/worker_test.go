package agent

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestWorkerUploadsLogsArtifactsAndResult(t *testing.T) {
	tmp := t.TempDir()
	if err := os.MkdirAll(filepath.Join(tmp, "target"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tmp, "target", "surefire.xml"), []byte("<testsuite />\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	request := testRequest(tmp)
	client := &fakeClient{request: &request}

	result, idle, err := Worker{
		AgentName: "host-local",
		Client:    client,
		Executor:  fakeExecutor{},
		Now:       func() time.Time { return time.Date(2026, 4, 11, 0, 0, 0, 0, time.UTC) },
	}.RunOnce()
	if err != nil {
		t.Fatal(err)
	}
	if idle {
		t.Fatal("expected job result, got idle")
	}
	if result.Status != "succeeded" {
		t.Fatalf("status = %s", result.Status)
	}
	if len(client.uploads) != 3 {
		t.Fatalf("uploads = %d", len(client.uploads))
	}
	if client.uploads[0].Role != "combined-log" || client.uploads[1].Role != "junit" || client.uploads[2].Role != "execution-metadata" {
		t.Fatalf("unexpected upload roles: %#v", client.uploads)
	}
	if client.uploads[0].RetentionClass != "analysis" || client.uploads[2].RetentionClass != "analysis" {
		t.Fatalf("expected analysis retention for persisted execution logs: %#v", client.uploads)
	}
	if client.result == nil || client.result.JobID != "job-1" {
		t.Fatalf("missing submitted result: %#v", client.result)
	}
}

func TestWorkerEmitsInProgressHeartbeats(t *testing.T) {
	tmp := t.TempDir()
	request := testRequest(tmp)
	client := &fakeClient{request: &request}

	result, idle, err := Worker{
		AgentName:         "host-local",
		Client:            client,
		Executor:          sleepingExecutor{duration: 20 * time.Millisecond},
		Now:               func() time.Time { return time.Now().UTC() },
		HeartbeatInterval: 5 * time.Millisecond,
	}.RunOnce()
	if err != nil {
		t.Fatal(err)
	}
	if idle {
		t.Fatal("expected job result, got idle")
	}
	client.mu.Lock()
	heartbeatCount := len(client.heartbeats)
	client.mu.Unlock()
	if heartbeatCount < 2 {
		t.Fatalf("expected periodic in-progress heartbeats, got %d", heartbeatCount)
	}
	if result.Heartbeat == "" {
		t.Fatalf("final result should preserve heartbeat: %#v", result)
	}
}

func TestWorkerReportsHeartbeatErrorsWithoutFailingJob(t *testing.T) {
	tmp := t.TempDir()
	request := testRequest(tmp)
	client := &fakeClient{request: &request, heartbeatErr: errors.New("heartbeat endpoint unavailable")}
	var heartbeatLog bytes.Buffer

	result, idle, err := Worker{
		AgentName:         "host-local",
		Client:            client,
		Executor:          fakeExecutor{},
		Now:               func() time.Time { return time.Date(2026, 4, 11, 0, 0, 0, 0, time.UTC) },
		HeartbeatErrorLog: &heartbeatLog,
	}.RunOnce()
	if err != nil {
		t.Fatal(err)
	}
	if idle {
		t.Fatal("expected job result, got idle")
	}
	if result.Status != "succeeded" {
		t.Fatalf("status = %s", result.Status)
	}
	if !strings.Contains(heartbeatLog.String(), "a2o-agent heartbeat failed job_id=job-1") || !strings.Contains(heartbeatLog.String(), "heartbeat endpoint unavailable") {
		t.Fatalf("heartbeat error log missing context: %q", heartbeatLog.String())
	}
}

func TestWorkerStopsHeartbeatBeforeSubmittingResult(t *testing.T) {
	tmp := t.TempDir()
	request := testRequest(tmp)
	client := &fakeClient{request: &request}

	_, idle, err := Worker{
		AgentName:         "host-local",
		Client:            client,
		Executor:          fakeExecutor{},
		Now:               func() time.Time { return time.Now().UTC() },
		HeartbeatInterval: time.Millisecond,
	}.RunOnce()
	if err != nil {
		t.Fatal(err)
	}
	if idle {
		t.Fatal("expected job result, got idle")
	}
	client.mu.Lock()
	heartbeatsAfterResult := client.heartbeatsAfterResult
	client.mu.Unlock()
	if heartbeatsAfterResult != 0 {
		t.Fatalf("heartbeat should stop before result submission, got %d after result", heartbeatsAfterResult)
	}
}

func TestWorkerUploadsAIRawLogWhenPresent(t *testing.T) {
	tmp := t.TempDir()
	request := testRequest(tmp)
	request.Env["A2O_AGENT_AI_RAW_LOG_ROOT"] = filepath.Join(tmp, "ai-raw-logs")
	rawPath := filepath.Join(request.Env["A2O_AGENT_AI_RAW_LOG_ROOT"], "Sample-42", "verification.log")
	if err := os.MkdirAll(filepath.Dir(rawPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(rawPath, []byte("assistant is thinking\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	client := &fakeClient{request: &request}

	result, idle, err := Worker{
		AgentName: "host-local",
		Client:    client,
		Executor:  fakeExecutor{},
		Now:       func() time.Time { return time.Date(2026, 4, 11, 0, 0, 0, 0, time.UTC) },
	}.RunOnce()
	if err != nil {
		t.Fatal(err)
	}
	if idle {
		t.Fatal("expected job result, got idle")
	}
	if result.Status != "succeeded" {
		t.Fatalf("status = %s", result.Status)
	}
	if roles := uploadRoles(client.uploads); !bytes.Equal([]byte(roles), []byte("combined-log,execution-metadata,ai-raw-log")) {
		t.Fatalf("unexpected upload roles: %s", roles)
	}
}

func TestWorkerMaterializesWorkspaceAndReturnsWorkerProtocolResult(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "sample-catalog-service")
	request := testRequest(".")
	request.Phase = "implementation"
	request.SourceDescriptor.WorkspaceKind = "ticket_workspace"
	request.WorkspaceRequest = ptr(testWorkspaceRequest("sample-catalog-service"))
	request.WorkspaceRequest.CleanupPolicy = "cleanup_after_job"
	request.WorkerProtocolRequest = map[string]any{
		"task_ref": "Sample#42",
		"phase":    "implementation",
	}
	client := &fakeClient{request: &request}
	var capturedRequestPath string
	var capturedRequestContent []byte

	result, idle, err := Worker{
		AgentName: "host-local",
		Client:    client,
		Executor: workerProtocolExecutor{
			requireSlotPaths: true,
			requestPath:      &capturedRequestPath,
			requestContent:   &capturedRequestContent,
		},
		Materializer: WorkspaceMaterializer{
			WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
			SourceAliases: map[string]string{
				"sample-catalog-service": sourceRoot,
			},
		},
		Now: func() time.Time { return time.Date(2026, 4, 11, 0, 0, 0, 0, time.UTC) },
	}.RunOnce()
	if err != nil {
		t.Fatal(err)
	}
	if idle {
		t.Fatal("expected job result, got idle")
	}
	if result.WorkspaceDescriptor.WorkspaceID != "Sample-42-ticket" {
		t.Fatalf("unexpected workspace descriptor: %#v", result.WorkspaceDescriptor)
	}
	if result.WorkerProtocolResult["status"] != "succeeded" {
		t.Fatalf("missing worker protocol result: %#v", result.WorkerProtocolResult)
	}
	expectedRequestPath := filepath.Join(tmp, "agent-workspaces", "Sample-42-ticket", ".a2o", "worker-request.json")
	if capturedRequestPath != expectedRequestPath {
		t.Fatalf("unexpected worker request path: %s", capturedRequestPath)
	}
	if !bytes.Contains(capturedRequestContent, []byte("\n  \"task_ref\":")) {
		t.Fatalf("worker request should be pretty-printed JSON: %s", string(capturedRequestContent))
	}
	slot := result.WorkspaceDescriptor.SlotDescriptors["repo_alpha"]
	if got := stringSlice(slot["changed_files"]); !bytes.Equal([]byte(join(got)), []byte("changed.txt")) {
		t.Fatalf("unexpected changed files: %#v", slot["changed_files"])
	}
	if slot["dirty_after"] != false {
		t.Fatalf("expected dirty_after=false after publish: %#v", slot)
	}
	if slot["publish_status"] != "committed" || slot["published"] != true {
		t.Fatalf("expected committed publish evidence: %#v", slot)
	}
	if slot["publish_before_head"] == slot["publish_after_head"] {
		t.Fatalf("expected publish head to advance: %#v", slot)
	}
	if head := trimTrailingNewline(git(t, sourceRoot, "rev-parse", "a3/work/Sample-42")); head != slot["publish_after_head"] {
		t.Fatalf("source branch was not advanced: head=%s slot=%#v", head, slot)
	}
	if roles := uploadRoles(client.uploads); !bytes.Equal([]byte(roles), []byte("combined-log,worker-result,execution-metadata")) {
		t.Fatalf("unexpected upload roles: %s", roles)
	}
	if _, err := os.Stat(filepath.Join(tmp, "agent-workspaces", "Sample-42-ticket")); !os.IsNotExist(err) {
		t.Fatalf("workspace was not cleaned up: %v", err)
	}
}

func TestWorkerSynthesizesNotificationWorkerProtocolResult(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "sample-catalog-service")
	request := testRequest(".")
	request.Phase = "implementation"
	request.SourceDescriptor.WorkspaceKind = "ticket_workspace"
	request.WorkspaceRequest = ptr(testWorkspaceRequest("sample-catalog-service"))
	request.WorkspaceRequest.PublishPolicy = nil
	request.WorkspaceRequest.CleanupPolicy = "cleanup_after_job"
	request.WorkerProtocolRequest = map[string]any{
		"command_intent": "notification",
		"schema":         "a2o.notification/v1",
		"event":          "task.blocked",
		"task_ref":       "Sample#42",
	}
	client := &fakeClient{request: &request}

	result, idle, err := Worker{
		AgentName: "host-local",
		Client:    client,
		Executor: outputExecutor{
			stdout: "notification stdout\n",
			stderr: "notification stderr\n",
		},
		Materializer: WorkspaceMaterializer{
			WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
			SourceAliases: map[string]string{
				"sample-catalog-service": sourceRoot,
			},
		},
		Now: func() time.Time { return time.Date(2026, 4, 11, 0, 0, 0, 0, time.UTC) },
	}.RunOnce()
	if err != nil {
		t.Fatal(err)
	}
	if idle {
		t.Fatal("expected job result, got idle")
	}
	diagnostics, ok := result.WorkerProtocolResult["diagnostics"].(map[string]any)
	if !ok {
		t.Fatalf("missing diagnostics: %#v", result.WorkerProtocolResult)
	}
	if diagnostics["stdout"] != "notification stdout\n" || diagnostics["stderr"] != "notification stderr\n" {
		t.Fatalf("unexpected notification diagnostics: %#v", diagnostics)
	}
}

func TestWorkerUsesEngineProvidedAgentEnvironmentForMaterialization(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "sample-catalog-service")
	request := testRequest(".")
	request.Phase = "implementation"
	request.SourceDescriptor.WorkspaceKind = "ticket_workspace"
	request.WorkspaceRequest = ptr(testWorkspaceRequest("sample-catalog-service"))
	request.WorkspaceRequest.CleanupPolicy = "cleanup_after_job"
	request.WorkerProtocolRequest = map[string]any{
		"task_ref": "Sample#42",
		"phase":    "implementation",
	}
	request.AgentEnvironment = &AgentEnvironment{
		WorkspaceRoot: filepath.Join(tmp, "engine-managed-workspaces"),
		SourcePaths: map[string]string{
			"sample-catalog-service": sourceRoot,
		},
		Env: map[string]string{
			"A3_ENGINE_MANAGED_ENV": "true",
		},
	}
	client := &fakeClient{request: &request}

	result, idle, err := Worker{
		AgentName: "host-local",
		Client:    client,
		Executor: envAwareWorkerProtocolExecutor{
			key:   "A3_ENGINE_MANAGED_ENV",
			value: "true",
			checks: map[string]string{
				"AUTOMATION_ISSUE_WORKSPACE": filepath.Join(tmp, "engine-managed-workspaces", "Sample-42-ticket"),
				"MAVEN_REPO_LOCAL":           filepath.Join(tmp, "engine-managed-workspaces", "Sample-42-ticket", ".work", "m2", "repository"),
			},
		},
		Now: func() time.Time { return time.Date(2026, 4, 11, 0, 0, 0, 0, time.UTC) },
	}.RunOnce()
	if err != nil {
		t.Fatal(err)
	}
	if idle {
		t.Fatal("expected job result, got idle")
	}
	if result.Status != "succeeded" {
		t.Fatalf("expected success from engine-managed environment, got %#v", result)
	}
	if result.WorkspaceDescriptor.WorkspaceID != "Sample-42-ticket" {
		t.Fatalf("unexpected workspace descriptor: %#v", result.WorkspaceDescriptor)
	}
	if _, err := os.Stat(filepath.Join(tmp, "engine-managed-workspaces", "Sample-42-ticket")); !os.IsNotExist(err) {
		t.Fatalf("workspace was not cleaned up: %v", err)
	}
}

func TestWorkerRejectsPublishWhenWorkerResultOmitsChangedFiles(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "sample-catalog-service")
	request := testRequest(".")
	request.Phase = "implementation"
	request.SourceDescriptor.WorkspaceKind = "ticket_workspace"
	request.WorkspaceRequest = ptr(testWorkspaceRequest("sample-catalog-service"))
	request.WorkerProtocolRequest = map[string]any{
		"task_ref": "Sample#42",
		"phase":    "implementation",
	}
	client := &fakeClient{request: &request}

	result, idle, err := Worker{
		AgentName: "host-local",
		Client:    client,
		Executor:  workerProtocolExecutor{omitChangedFiles: true},
		Materializer: WorkspaceMaterializer{
			WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
			SourceAliases: map[string]string{
				"sample-catalog-service": sourceRoot,
			},
		},
		Now: func() time.Time { return time.Date(2026, 4, 11, 0, 0, 0, 0, time.UTC) },
	}.RunOnce()
	if err != nil {
		t.Fatal(err)
	}
	if idle {
		t.Fatal("expected failed job result, got idle")
	}
	if result.Status != "failed" {
		t.Fatalf("expected publish failure, got %#v", result)
	}
	if result.WorkerProtocolResult["failing_command"] != "agent_workspace_publish" {
		t.Fatalf("unexpected failure payload: %#v", result.WorkerProtocolResult)
	}
	if head := trimTrailingNewline(git(t, sourceRoot, "rev-parse", "a3/work/Sample-42")); head == "" || head != result.WorkspaceDescriptor.SlotDescriptors["repo_alpha"]["resolved_head"] {
		t.Fatalf("source branch should not advance on publish failure: head=%s descriptor=%#v", head, result.WorkspaceDescriptor.SlotDescriptors["repo_alpha"])
	}
}

func TestWorkerSubmitsFailedResultWhenMaterializationFails(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "sample-catalog-service")
	if err := os.WriteFile(filepath.Join(sourceRoot, "dirty.txt"), []byte("dirty\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	request := testRequest(".")
	request.SourceDescriptor.WorkspaceKind = "ticket_workspace"
	request.WorkspaceRequest = ptr(testWorkspaceRequest("sample-catalog-service"))
	client := &fakeClient{request: &request}

	result, idle, err := Worker{
		AgentName: "host-local",
		Client:    client,
		Executor:  failingExecutor{},
		Materializer: WorkspaceMaterializer{
			WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
			SourceAliases: map[string]string{
				"sample-catalog-service": sourceRoot,
			},
		},
		Now: func() time.Time { return time.Date(2026, 4, 11, 0, 0, 0, 0, time.UTC) },
	}.RunOnce()
	if err != nil {
		t.Fatal(err)
	}
	if idle {
		t.Fatal("expected failed job result, got idle")
	}
	if result.Status != "failed" || result.ExitCode == nil || *result.ExitCode != 1 {
		t.Fatalf("unexpected failed result: %#v", result)
	}
	if client.result == nil || client.result.Status != "failed" {
		t.Fatalf("failed result was not submitted: %#v", client.result)
	}
}

func TestWorkerRunsNativeMergeJobs(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "sample-catalog-service")
	if err := os.WriteFile(filepath.Join(sourceRoot, "feature.txt"), []byte("feature\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, sourceRoot, "add", "feature.txt")
	git(t, sourceRoot, "commit", "-q", "-m", "feature")
	git(t, sourceRoot, "branch", "-f", "a3/work/Sample-42", "HEAD")
	git(t, sourceRoot, "branch", "a3/live", "HEAD~1")
	request := testRequest(".")
	request.Phase = "merge"
	request.MergeRequest = &MergeRequest{
		WorkspaceID: "merge-Sample-42",
		Policy:      "ff_only",
		Slots: map[string]MergeSlotRequest{
			"repo_alpha": {
				Source:    WorkspaceSourceRequest{Kind: "local_git", Alias: "sample-catalog-service"},
				SourceRef: "refs/heads/a3/work/Sample-42",
				TargetRef: "refs/heads/a3/live",
			},
		},
	}
	client := &fakeClient{request: &request}

	result, idle, err := Worker{
		AgentName: "host-local",
		Client:    client,
		Executor:  failingExecutor{},
		Materializer: WorkspaceMaterializer{
			WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
			SourceAliases: map[string]string{
				"sample-catalog-service": sourceRoot,
			},
		},
		Now: func() time.Time { return time.Date(2026, 4, 11, 0, 0, 0, 0, time.UTC) },
	}.RunOnce()
	if err != nil {
		t.Fatal(err)
	}
	if idle || result.Status != "succeeded" {
		t.Fatalf("expected merge success, idle=%v result=%#v", idle, result)
	}
	slot := result.WorkspaceDescriptor.SlotDescriptors["repo_alpha"]
	if slot["merge_status"] != "merged" || slot["project_repo_mutator"] != "a2o-agent" {
		t.Fatalf("missing merge evidence: %#v", slot)
	}
}

func TestWorkerReturnsIdleWithoutJob(t *testing.T) {
	_, idle, err := Worker{
		AgentName: "host-local",
		Client:    &fakeClient{},
		Executor:  fakeExecutor{},
	}.RunOnce()
	if err != nil {
		t.Fatal(err)
	}
	if !idle {
		t.Fatal("expected idle")
	}
}

func TestWorkerRunLoopStopsAfterMaxIterations(t *testing.T) {
	tmp := t.TempDir()
	request := testRequest(tmp)
	client := &fakeClient{requests: []*JobRequest{nil, &request, nil}}
	var sleeps []time.Duration

	result, err := Worker{
		AgentName: "host-local",
		Client:    client,
		Executor:  fakeExecutor{},
		Now:       func() time.Time { return time.Date(2026, 4, 11, 0, 0, 0, 0, time.UTC) },
	}.RunLoop(LoopOptions{
		PollInterval:  25 * time.Millisecond,
		MaxIterations: 3,
		Sleep: func(duration time.Duration) {
			sleeps = append(sleeps, duration)
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Iterations != 3 || result.Jobs != 1 || result.Idle != 2 {
		t.Fatalf("unexpected loop result: %#v", result)
	}
	if len(sleeps) != 2 || sleeps[0] != 25*time.Millisecond || sleeps[1] != 25*time.Millisecond {
		t.Fatalf("unexpected sleeps: %#v", sleeps)
	}
}

type fakeExecutor struct{}

func (fakeExecutor) Execute(JobRequest) ExecutionResult {
	code := 0
	return ExecutionResult{
		Status:      "succeeded",
		ExitCode:    &code,
		CombinedLog: []byte("all checks passed\n"),
	}
}

type outputExecutor struct {
	stdout string
	stderr string
}

func (executor outputExecutor) Execute(JobRequest) ExecutionResult {
	code := 0
	return ExecutionResult{
		Status:      "succeeded",
		ExitCode:    &code,
		Stdout:      []byte(executor.stdout),
		Stderr:      []byte(executor.stderr),
		CombinedLog: []byte(executor.stdout + executor.stderr),
	}
}

type sleepingExecutor struct {
	duration time.Duration
}

func (executor sleepingExecutor) Execute(JobRequest) ExecutionResult {
	time.Sleep(executor.duration)
	return fakeExecutor{}.Execute(JobRequest{})
}

type workerProtocolExecutor struct {
	omitChangedFiles bool
	requireSlotPaths bool
	requestPath      *string
	requestContent   *[]byte
}

type envAwareWorkerProtocolExecutor struct {
	key    string
	value  string
	checks map[string]string
}

func (executor envAwareWorkerProtocolExecutor) Execute(request JobRequest) ExecutionResult {
	if request.Env[executor.key] != executor.value {
		code := 1
		return ExecutionResult{Status: "failed", ExitCode: &code, CombinedLog: []byte("missing engine-managed agent environment")}
	}
	for key, value := range executor.checks {
		if request.Env[key] != value {
			code := 1
			return ExecutionResult{Status: "failed", ExitCode: &code, CombinedLog: []byte("missing workspace automation environment")}
		}
	}
	return workerProtocolExecutor{requireSlotPaths: true}.Execute(request)
}

func (executor workerProtocolExecutor) Execute(request JobRequest) ExecutionResult {
	if executor.requestPath != nil {
		*executor.requestPath = request.Env["A2O_WORKER_REQUEST_PATH"]
	}
	content, err := os.ReadFile(request.Env["A2O_WORKER_REQUEST_PATH"])
	if err != nil {
		code := 1
		return ExecutionResult{Status: "failed", ExitCode: &code, CombinedLog: []byte(err.Error())}
	}
	if executor.requestContent != nil {
		*executor.requestContent = append((*executor.requestContent)[:0], content...)
	}
	var payload map[string]any
	if err := json.Unmarshal(content, &payload); err != nil {
		code := 1
		return ExecutionResult{Status: "failed", ExitCode: &code, CombinedLog: []byte(err.Error())}
	}
	if executor.requireSlotPaths {
		slotPaths, ok := payload["slot_paths"].(map[string]any)
		if !ok || slotPaths["repo_alpha"] == "" {
			code := 1
			return ExecutionResult{Status: "failed", ExitCode: &code, CombinedLog: []byte("missing materialized slot_paths")}
		}
	}
	result := map[string]any{
		"status":   "succeeded",
		"success":  true,
		"task_ref": payload["task_ref"],
	}
	if !executor.omitChangedFiles {
		result["changed_files"] = map[string]any{
			"repo_alpha": []string{"changed.txt"},
		}
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		code := 1
		return ExecutionResult{Status: "failed", ExitCode: &code, CombinedLog: []byte(err.Error())}
	}
	if err := os.WriteFile(request.Env["A2O_WORKER_RESULT_PATH"], encoded, 0o600); err != nil {
		code := 1
		return ExecutionResult{Status: "failed", ExitCode: &code, CombinedLog: []byte(err.Error())}
	}
	slotPaths, _ := payload["slot_paths"].(map[string]any)
	slotPath, _ := slotPaths["repo_alpha"].(string)
	if slotPath == "" {
		slotPath = filepath.Join(request.WorkingDir, "repo_alpha")
	}
	if err := os.WriteFile(filepath.Join(slotPath, "changed.txt"), []byte("changed\n"), 0o644); err != nil {
		code := 1
		return ExecutionResult{Status: "failed", ExitCode: &code, CombinedLog: []byte(err.Error())}
	}
	if err := os.MkdirAll(filepath.Join(request.WorkingDir, ".a2o"), 0o755); err != nil {
		code := 1
		return ExecutionResult{Status: "failed", ExitCode: &code, CombinedLog: []byte(err.Error())}
	}
	if err := os.WriteFile(filepath.Join(request.WorkingDir, ".a2o", "ignored.txt"), []byte("ignored\n"), 0o644); err != nil {
		code := 1
		return ExecutionResult{Status: "failed", ExitCode: &code, CombinedLog: []byte(err.Error())}
	}
	code := 0
	return ExecutionResult{Status: "succeeded", ExitCode: &code, CombinedLog: []byte("worker protocol ok\n")}
}

type failingExecutor struct{}

func (failingExecutor) Execute(JobRequest) ExecutionResult {
	panic("executor must not run")
}

type fakeClient struct {
	mu                    sync.Mutex
	request               *JobRequest
	requests              []*JobRequest
	uploads               []ArtifactUpload
	heartbeats            []string
	heartbeatsAfterResult int
	heartbeatErr          error
	result                *JobResult
}

func (f *fakeClient) ClaimNext(string) (*JobRequest, error) {
	if len(f.requests) > 0 {
		request := f.requests[0]
		f.requests = f.requests[1:]
		return request, nil
	}
	return f.request, nil
}

func (f *fakeClient) UploadArtifact(upload ArtifactUpload, content []byte) (ArtifactUpload, error) {
	sum := sha256.Sum256(content)
	expected := "sha256:" + hex.EncodeToString(sum[:])
	if upload.Digest != expected {
		panic("digest mismatch")
	}
	f.uploads = append(f.uploads, upload)
	return upload, nil
}

func (f *fakeClient) Heartbeat(jobID string, heartbeat string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.result != nil {
		f.heartbeatsAfterResult++
	}
	f.heartbeats = append(f.heartbeats, jobID+"="+heartbeat)
	return f.heartbeatErr
}

func (f *fakeClient) SubmitResult(result JobResult) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.result = &result
	return nil
}

func testRequest(workingDir string) JobRequest {
	return JobRequest{
		JobID:          "job-1",
		TaskRef:        "Sample#42",
		Phase:          "verification",
		RuntimeProfile: "host-local",
		SourceDescriptor: SourceDescriptor{
			WorkspaceKind: "runtime_workspace",
			SourceType:    "detached_commit",
			Ref:           "abc123",
			TaskRef:       "Sample#42",
		},
		WorkingDir:     workingDir,
		Command:        "task",
		Args:           []string{"test:all"},
		Env:            map[string]string{},
		TimeoutSeconds: 60,
		ArtifactRules: []map[string]string{
			{
				"role":            "junit",
				"glob":            "target/*.xml",
				"retention_class": "evidence",
				"media_type":      "application/xml",
			},
		},
	}
}

func TestSafeID(t *testing.T) {
	got := safeID("Sample#42 junit/report.xml")
	if bytes.ContainsAny([]byte(got), "#/ ") {
		t.Fatalf("unsafe id: %s", got)
	}
}

func ptr[T any](value T) *T {
	return &value
}

func uploadRoles(uploads []ArtifactUpload) string {
	roles := make([]byte, 0)
	for index, upload := range uploads {
		if index > 0 {
			roles = append(roles, ',')
		}
		roles = append(roles, upload.Role...)
	}
	return string(roles)
}

func stringSlice(value any) []string {
	switch typed := value.(type) {
	case []string:
		return typed
	case []any:
		result := make([]string, 0, len(typed))
		for _, item := range typed {
			if stringItem, ok := item.(string); ok {
				result = append(result, stringItem)
			}
		}
		return result
	default:
		return nil
	}
}

func join(values []string) string {
	var out []byte
	for index, value := range values {
		if index > 0 {
			out = append(out, ',')
		}
		out = append(out, value...)
	}
	return string(out)
}
