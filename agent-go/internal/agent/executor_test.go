package agent

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestExecutorRunsCommand(t *testing.T) {
	request := testRequest(t.TempDir())
	request.Command = os.Args[0]
	request.Args = []string{"-test.run=TestHelperProcess", "--", "ok"}
	request.Env = map[string]string{"GO_WANT_HELPER_PROCESS": "1"}

	result := Executor{}.Execute(request)
	if result.Status != "succeeded" {
		t.Fatalf("status = %s log=%s", result.Status, string(result.CombinedLog))
	}
	if result.ExitCode == nil || *result.ExitCode != 0 {
		t.Fatalf("exit code = %#v", result.ExitCode)
	}
}

func TestExecutorMissingCommandFails(t *testing.T) {
	request := testRequest(t.TempDir())
	request.Command = "missing-a3-agent-command"
	request.Args = nil

	result := Executor{}.Execute(request)
	if result.Status != "failed" {
		t.Fatalf("status = %s", result.Status)
	}
	if result.ExitCode == nil || *result.ExitCode != 127 {
		t.Fatalf("exit code = %#v", result.ExitCode)
	}
}

func TestExecutorWritesLiveLogWhenConfigured(t *testing.T) {
	tempDir := t.TempDir()
	request := testRequest(tempDir)
	request.TaskRef = "A2O#42"
	request.Phase = "implementation"
	request.Command = os.Args[0]
	request.Args = []string{"-test.run=TestHelperProcess", "--", "ok"}
	request.Env = map[string]string{
		"GO_WANT_HELPER_PROCESS":  "1",
		"A2O_AGENT_LIVE_LOG_ROOT": filepath.Join(tempDir, "live-logs"),
	}

	result := Executor{}.Execute(request)
	if result.Status != "succeeded" {
		t.Fatalf("status = %s log=%s", result.Status, string(result.CombinedLog))
	}

	body, err := os.ReadFile(filepath.Join(tempDir, "live-logs", "A2O-42", "implementation.log"))
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != string(result.CombinedLog) {
		t.Fatalf("live log mismatch: got=%q want=%q", string(body), string(result.CombinedLog))
	}
}

func TestExecutorWritesDecompositionLiveLogByCommandIntent(t *testing.T) {
	tempDir := t.TempDir()
	request := testRequest(tempDir)
	request.TaskRef = "A2O#44"
	request.Phase = "verification"
	request.WorkerProtocolRequest = map[string]any{"command_intent": "decomposition_propose"}
	request.Command = os.Args[0]
	request.Args = []string{"-test.run=TestHelperProcess", "--", "ok"}
	request.Env = map[string]string{
		"GO_WANT_HELPER_PROCESS":  "1",
		"A2O_AGENT_LIVE_LOG_ROOT": filepath.Join(tempDir, "live-logs"),
	}

	result := Executor{}.Execute(request)
	if result.Status != "succeeded" {
		t.Fatalf("status = %s log=%s", result.Status, string(result.CombinedLog))
	}

	if _, err := os.Stat(filepath.Join(tempDir, "live-logs", "A2O-44", "verification.log")); !os.IsNotExist(err) {
		t.Fatalf("decomposition live log should not reuse verification.log, err=%v", err)
	}
	body, err := os.ReadFile(filepath.Join(tempDir, "live-logs", "A2O-44", "decomposition_propose.log"))
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != string(result.CombinedLog) {
		t.Fatalf("live log mismatch: got=%q want=%q", string(body), string(result.CombinedLog))
	}
}

func TestExecutorPrefersRequestLiveLogRootOverProcessEnv(t *testing.T) {
	tempDir := t.TempDir()
	t.Setenv("A2O_AGENT_LIVE_LOG_ROOT", filepath.Join(tempDir, "wrong-live-logs"))
	request := testRequest(tempDir)
	request.TaskRef = "A2O#43"
	request.Phase = "review"
	request.Command = os.Args[0]
	request.Args = []string{"-test.run=TestHelperProcess", "--", "ok"}
	request.Env = map[string]string{
		"GO_WANT_HELPER_PROCESS":  "1",
		"A2O_AGENT_LIVE_LOG_ROOT": filepath.Join(tempDir, "live-logs"),
	}

	result := Executor{}.Execute(request)
	if result.Status != "succeeded" {
		t.Fatalf("status = %s log=%s", result.Status, string(result.CombinedLog))
	}
	if _, err := os.Stat(filepath.Join(tempDir, "wrong-live-logs", "A2O-43", "review.log")); !os.IsNotExist(err) {
		t.Fatalf("unexpected process-env live log file err=%v", err)
	}
	body, err := os.ReadFile(filepath.Join(tempDir, "live-logs", "A2O-43", "review.log"))
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != string(result.CombinedLog) {
		t.Fatalf("live log mismatch: got=%q want=%q", string(body), string(result.CombinedLog))
	}
}

func TestBestEffortWriterSwallowsWriteErrors(t *testing.T) {
	written, err := bestEffortWriter{writer: errWriter{}}.Write([]byte("hello"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if written != len("hello") {
		t.Fatalf("written = %d, want %d", written, len("hello"))
	}
}

func TestHelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_HELPER_PROCESS") != "1" {
		return
	}
	os.Exit(0)
}

type errWriter struct{}

func (errWriter) Write(_ []byte) (int, error) {
	return 0, errors.New("disk full")
}
