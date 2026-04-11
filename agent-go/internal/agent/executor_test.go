package agent

import (
	"os"
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

func TestHelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_HELPER_PROCESS") != "1" {
		return
	}
	os.Exit(0)
}
