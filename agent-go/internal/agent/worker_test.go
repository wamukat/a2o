package agent

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
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

type fakeExecutor struct{}

func (fakeExecutor) Execute(JobRequest) ExecutionResult {
	code := 0
	return ExecutionResult{
		Status:      "succeeded",
		ExitCode:    &code,
		CombinedLog: []byte("all checks passed\n"),
	}
}

type fakeClient struct {
	request *JobRequest
	uploads []ArtifactUpload
	result  *JobResult
}

func (f *fakeClient) ClaimNext(string) (*JobRequest, error) {
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
