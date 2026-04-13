package agent

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
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
	if len(client.uploads) != 2 {
		t.Fatalf("uploads = %d", len(client.uploads))
	}
	if client.uploads[0].Role != "combined-log" || client.uploads[1].Role != "junit" {
		t.Fatalf("unexpected upload roles: %#v", client.uploads)
	}
	if client.result == nil || client.result.JobID != "job-1" {
		t.Fatalf("missing submitted result: %#v", client.result)
	}
}

func TestWorkerMaterializesWorkspaceAndReturnsWorkerProtocolResult(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "member-portal-starters")
	request := testRequest(".")
	request.Phase = "implementation"
	request.SourceDescriptor.WorkspaceKind = "ticket_workspace"
	request.WorkspaceRequest = ptr(testWorkspaceRequest("member-portal-starters"))
	request.WorkspaceRequest.CleanupPolicy = "cleanup_after_job"
	request.WorkerProtocolRequest = map[string]any{
		"task_ref": "Portal#42",
		"phase":    "implementation",
	}
	client := &fakeClient{request: &request}

	result, idle, err := Worker{
		AgentName: "host-local",
		Client:    client,
		Executor:  workerProtocolExecutor{requireSlotPaths: true},
		Materializer: WorkspaceMaterializer{
			WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
			SourceAliases: map[string]string{
				"member-portal-starters": sourceRoot,
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
	if result.WorkspaceDescriptor.WorkspaceID != "Portal-42-ticket" {
		t.Fatalf("unexpected workspace descriptor: %#v", result.WorkspaceDescriptor)
	}
	if result.WorkerProtocolResult["status"] != "succeeded" {
		t.Fatalf("missing worker protocol result: %#v", result.WorkerProtocolResult)
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
	if head := trimTrailingNewline(git(t, sourceRoot, "rev-parse", "a3/work/Portal-42")); head != slot["publish_after_head"] {
		t.Fatalf("source branch was not advanced: head=%s slot=%#v", head, slot)
	}
	if roles := uploadRoles(client.uploads); !bytes.Equal([]byte(roles), []byte("combined-log,worker-result")) {
		t.Fatalf("unexpected upload roles: %s", roles)
	}
	if _, err := os.Stat(filepath.Join(tmp, "agent-workspaces", "Portal-42-ticket")); !os.IsNotExist(err) {
		t.Fatalf("workspace was not cleaned up: %v", err)
	}
}

func TestWorkerUsesEngineProvidedAgentEnvironmentForMaterialization(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "member-portal-starters")
	request := testRequest(".")
	request.Phase = "implementation"
	request.SourceDescriptor.WorkspaceKind = "ticket_workspace"
	request.WorkspaceRequest = ptr(testWorkspaceRequest("member-portal-starters"))
	request.WorkspaceRequest.CleanupPolicy = "cleanup_after_job"
	request.WorkerProtocolRequest = map[string]any{
		"task_ref": "Portal#42",
		"phase":    "implementation",
	}
	request.AgentEnvironment = &AgentEnvironment{
		WorkspaceRoot: filepath.Join(tmp, "engine-managed-workspaces"),
		SourcePaths: map[string]string{
			"member-portal-starters": sourceRoot,
		},
		Env: map[string]string{
			"A3_ENGINE_MANAGED_ENV": "true",
		},
	}
	client := &fakeClient{request: &request}

	result, idle, err := Worker{
		AgentName: "host-local",
		Client:    client,
		Executor:  envAwareWorkerProtocolExecutor{key: "A3_ENGINE_MANAGED_ENV", value: "true"},
		Now:       func() time.Time { return time.Date(2026, 4, 11, 0, 0, 0, 0, time.UTC) },
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
	if result.WorkspaceDescriptor.WorkspaceID != "Portal-42-ticket" {
		t.Fatalf("unexpected workspace descriptor: %#v", result.WorkspaceDescriptor)
	}
	if _, err := os.Stat(filepath.Join(tmp, "engine-managed-workspaces", "Portal-42-ticket")); !os.IsNotExist(err) {
		t.Fatalf("workspace was not cleaned up: %v", err)
	}
}

func TestWorkerRejectsPublishWhenWorkerResultOmitsChangedFiles(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "member-portal-starters")
	request := testRequest(".")
	request.Phase = "implementation"
	request.SourceDescriptor.WorkspaceKind = "ticket_workspace"
	request.WorkspaceRequest = ptr(testWorkspaceRequest("member-portal-starters"))
	request.WorkerProtocolRequest = map[string]any{
		"task_ref": "Portal#42",
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
				"member-portal-starters": sourceRoot,
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
	if head := trimTrailingNewline(git(t, sourceRoot, "rev-parse", "a3/work/Portal-42")); head == "" || head != result.WorkspaceDescriptor.SlotDescriptors["repo_alpha"]["resolved_head"] {
		t.Fatalf("source branch should not advance on publish failure: head=%s descriptor=%#v", head, result.WorkspaceDescriptor.SlotDescriptors["repo_alpha"])
	}
}

func TestWorkerSubmitsFailedResultWhenMaterializationFails(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "member-portal-starters")
	if err := os.WriteFile(filepath.Join(sourceRoot, "dirty.txt"), []byte("dirty\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	request := testRequest(".")
	request.SourceDescriptor.WorkspaceKind = "ticket_workspace"
	request.WorkspaceRequest = ptr(testWorkspaceRequest("member-portal-starters"))
	client := &fakeClient{request: &request}

	result, idle, err := Worker{
		AgentName: "host-local",
		Client:    client,
		Executor:  failingExecutor{},
		Materializer: WorkspaceMaterializer{
			WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
			SourceAliases: map[string]string{
				"member-portal-starters": sourceRoot,
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
	sourceRoot := createGitSource(t, tmp, "member-portal-starters")
	if err := os.WriteFile(filepath.Join(sourceRoot, "feature.txt"), []byte("feature\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, sourceRoot, "add", "feature.txt")
	git(t, sourceRoot, "commit", "-q", "-m", "feature")
	git(t, sourceRoot, "branch", "-f", "a3/work/Portal-42", "HEAD")
	git(t, sourceRoot, "branch", "a3/live", "HEAD~1")
	request := testRequest(".")
	request.Phase = "merge"
	request.MergeRequest = &MergeRequest{
		WorkspaceID: "merge-Portal-42",
		Policy:      "ff_only",
		Slots: map[string]MergeSlotRequest{
			"repo_alpha": {
				Source:    WorkspaceSourceRequest{Kind: "local_git", Alias: "member-portal-starters"},
				SourceRef: "refs/heads/a3/work/Portal-42",
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
				"member-portal-starters": sourceRoot,
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
	if slot["merge_status"] != "merged" || slot["project_repo_mutator"] != "a3-agent" {
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

type workerProtocolExecutor struct {
	omitChangedFiles bool
	requireSlotPaths bool
}

type envAwareWorkerProtocolExecutor struct {
	key   string
	value string
}

func (executor envAwareWorkerProtocolExecutor) Execute(request JobRequest) ExecutionResult {
	if request.Env[executor.key] != executor.value {
		code := 1
		return ExecutionResult{Status: "failed", ExitCode: &code, CombinedLog: []byte("missing engine-managed agent environment")}
	}
	return workerProtocolExecutor{requireSlotPaths: true}.Execute(request)
}

func (executor workerProtocolExecutor) Execute(request JobRequest) ExecutionResult {
	content, err := os.ReadFile(request.Env["A3_WORKER_REQUEST_PATH"])
	if err != nil {
		code := 1
		return ExecutionResult{Status: "failed", ExitCode: &code, CombinedLog: []byte(err.Error())}
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
	if err := os.WriteFile(request.Env["A3_WORKER_RESULT_PATH"], encoded, 0o600); err != nil {
		code := 1
		return ExecutionResult{Status: "failed", ExitCode: &code, CombinedLog: []byte(err.Error())}
	}
	if err := os.WriteFile(filepath.Join(request.WorkingDir, "repo-alpha", "changed.txt"), []byte("changed\n"), 0o644); err != nil {
		code := 1
		return ExecutionResult{Status: "failed", ExitCode: &code, CombinedLog: []byte(err.Error())}
	}
	if err := os.WriteFile(filepath.Join(request.WorkingDir, ".a3", "ignored.txt"), []byte("ignored\n"), 0o644); err != nil {
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
	request  *JobRequest
	requests []*JobRequest
	uploads  []ArtifactUpload
	result   *JobResult
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

func (f *fakeClient) SubmitResult(result JobResult) error {
	f.result = &result
	return nil
}

func testRequest(workingDir string) JobRequest {
	return JobRequest{
		JobID:          "job-1",
		TaskRef:        "Portal#42",
		Phase:          "verification",
		RuntimeProfile: "host-local",
		SourceDescriptor: SourceDescriptor{
			WorkspaceKind: "runtime_workspace",
			SourceType:    "detached_commit",
			Ref:           "abc123",
			TaskRef:       "Portal#42",
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
	got := safeID("Portal#42 junit/report.xml")
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
