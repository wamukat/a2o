package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestPreScanConfigPath(t *testing.T) {
	cases := map[string][]string{
		"/tmp/profile-a.json": {"-config", "/tmp/profile-a.json"},
		"/tmp/profile-b.json": {"--config", "/tmp/profile-b.json"},
		"/tmp/profile-c.json": {"-config=/tmp/profile-c.json"},
		"/tmp/profile-d.json": {"--config=/tmp/profile-d.json"},
	}
	for expected, args := range cases {
		if got := preScanConfigPath(args); got != expected {
			t.Fatalf("preScanConfigPath(%v) = %q, want %q", args, got, expected)
		}
	}
}

func TestMergeSourceAliases(t *testing.T) {
	got := mergeSourceAliases(
		map[string]string{"repo-a": "/config/a", "repo-b": "/config/b"},
		map[string]string{"repo-b": "/env/b"},
		map[string]string{"repo-c": "/cli/c"},
	)
	want := map[string]string{
		"repo-a": "/config/a",
		"repo-b": "/env/b",
		"repo-c": "/cli/c",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("merged aliases = %#v, want %#v", got, want)
	}
}

func TestRunDoctorValidatesRuntimeProfile(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createDoctorGitSource(t, tmp)
	configPath := filepath.Join(tmp, "agent-profile.json")
	if err := os.WriteFile(configPath, []byte(`{
  "agent": "dev-env",
  "control_plane_url": "http://a3-runtime:7393",
  "workspace_root": "`+filepath.ToSlash(filepath.Join(tmp, "workspaces"))+`",
  "source_aliases": {
    "sample-catalog-service": "`+filepath.ToSlash(sourceRoot)+`"
  }
}`), 0o644); err != nil {
		t.Fatal(err)
	}

	if code := run([]string{"doctor", "-config", configPath}); code != 0 {
		t.Fatalf("doctor exit code = %d", code)
	}
}

func TestRunDoctorAcceptsEngineManagedEnvironmentFlags(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createDoctorGitSource(t, tmp)

	code := run([]string{
		"doctor",
		"--agent", "dev-env",
		"--control-plane-url", "http://a3-runtime:7393",
		"--workspace-root", filepath.Join(tmp, "workspaces"),
		"--source-path", "sample-catalog-service=" + sourceRoot,
		"--required-bin", "git",
	})
	if code != 0 {
		t.Fatalf("doctor exit code = %d", code)
	}
}

func TestRunDoctorAcceptsEngineAlias(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createDoctorGitSource(t, tmp)

	code := run([]string{
		"doctor",
		"--agent", "dev-env",
		"--engine", "http://a3-runtime:7393",
		"--workspace-root", filepath.Join(tmp, "workspaces"),
		"--source-path", "sample-catalog-service=" + sourceRoot,
		"--required-bin", "git",
	})
	if code != 0 {
		t.Fatalf("doctor exit code = %d", code)
	}
}

func TestRunDoctorRejectsMissingRequiredBin(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createDoctorGitSource(t, tmp)

	code := run([]string{
		"doctor",
		"--workspace-root", filepath.Join(tmp, "workspaces"),
		"--source-path", "sample-catalog-service=" + sourceRoot,
		"--required-bin", "a3-missing-required-bin-for-test",
	})
	if code == 0 {
		t.Fatal("doctor should fail when a required bin is missing")
	}
}

func TestResolveAgentTokenReadsTokenFile(t *testing.T) {
	tokenPath := filepath.Join(t.TempDir(), "agent-token")
	if err := os.WriteFile(tokenPath, []byte("file-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	token, err := resolveAgentToken("", tokenPath, "profile-token")
	if err != nil {
		t.Fatal(err)
	}
	if token != "file-token" {
		t.Fatalf("token = %q", token)
	}
}

func TestResolveAgentTokenPrefersDirectToken(t *testing.T) {
	tokenPath := filepath.Join(t.TempDir(), "agent-token")
	if err := os.WriteFile(tokenPath, []byte("file-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	token, err := resolveAgentToken("direct-token", tokenPath, "profile-token")
	if err != nil {
		t.Fatal(err)
	}
	if token != "direct-token" {
		t.Fatalf("token = %q", token)
	}
}

func TestRunWorkerStdinBundleExecutesConfiguredCommand(t *testing.T) {
	tmp := t.TempDir()
	requestPath := filepath.Join(tmp, "request.json")
	resultPath := filepath.Join(tmp, "result.json")
	promptPath := filepath.Join(tmp, "prompt.json")
	launcherPath := filepath.Join(tmp, "launcher.json")
	scriptPath := filepath.Join(tmp, "executor.sh")

	if err := os.WriteFile(requestPath, []byte(`{
  "task_ref": "A2O#2",
  "run_ref": "run-1",
  "phase": "review",
  "phase_runtime": {},
  "task_packet": {"title": "review me"}
}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(scriptPath, []byte(`#!/bin/sh
set -eu
cat > "$1"
cat > "$2" <<'JSON'
{
  "task_ref": "A2O#2",
  "run_ref": "run-1",
  "phase": "review",
  "success": true,
  "summary": "review clean",
  "failing_command": null,
  "observed_state": null,
  "rework_required": false
}
JSON
`), 0o755); err != nil {
		t.Fatal(err)
	}
	launcher := `{
  "executor": {
    "kind": "command",
    "prompt_transport": "stdin-bundle",
    "result": {"mode": "file"},
    "schema": {"mode": "file"},
    "default_profile": {
      "command": ["` + scriptPath + `", "` + promptPath + `", "{{result_path}}"],
      "env": {}
    },
    "phase_profiles": {}
  }
}`
	if err := os.WriteFile(launcherPath, []byte(launcher), 0o644); err != nil {
		t.Fatal(err)
	}

	t.Setenv("A3_WORKER_REQUEST_PATH", requestPath)
	t.Setenv("A3_WORKER_RESULT_PATH", resultPath)
	t.Setenv("A3_WORKER_LAUNCHER_CONFIG_PATH", launcherPath)
	t.Setenv("A3_WORKSPACE_ROOT", tmp)

	if code := run([]string{"worker", "stdin-bundle"}); code != 0 {
		t.Fatalf("worker exit code = %d", code)
	}

	resultBody, err := os.ReadFile(resultPath)
	if err != nil {
		t.Fatal(err)
	}
	var result map[string]any
	if err := json.Unmarshal(resultBody, &result); err != nil {
		t.Fatal(err)
	}
	if result["success"] != true || result["summary"] != "review clean" {
		t.Fatalf("unexpected result: %s", resultBody)
	}
	promptBody, err := os.ReadFile(promptPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(promptBody), "You are the A2O worker") || !strings.Contains(string(promptBody), "A2O#2") {
		t.Fatalf("prompt should contain A2O worker bundle, got %s", promptBody)
	}
}

func createDoctorGitSource(t *testing.T, root string) string {
	t.Helper()
	sourceRoot := filepath.Join(root, "source")
	if err := os.MkdirAll(sourceRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	runGit(t, sourceRoot, "init", "-q")
	runGit(t, sourceRoot, "config", "user.name", "A3 Test")
	runGit(t, sourceRoot, "config", "user.email", "a3-test@example.com")
	if err := os.WriteFile(filepath.Join(sourceRoot, "README.md"), []byte("source\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, sourceRoot, "add", "README.md")
	runGit(t, sourceRoot, "commit", "-q", "-m", "initial commit")
	return sourceRoot
}

func runGit(t *testing.T, root string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v failed: %v: %s", args, err, out)
	}
}
