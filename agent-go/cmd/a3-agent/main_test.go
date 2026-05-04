package main

import (
	"encoding/json"
	"fmt"
	"github.com/wamukat/a3-engine/agent-go/internal/errorpolicy"
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

func TestPublicAgentEnvironmentConfig(t *testing.T) {
	t.Setenv("A2O_AGENT_CONFIG", "/tmp/public-profile.json")
	t.Setenv("A2O_AGENT_NAME", "public-agent")
	t.Setenv("A2O_AGENT_PROJECT_KEY", "portal")
	t.Setenv("A2O_AGENT_POLL_INTERVAL", "3s")
	t.Setenv("A2O_AGENT_MAX_ITERATIONS", "4")

	if got := preScanConfigPath(nil); got != "/tmp/public-profile.json" {
		t.Fatalf("preScanConfigPath env = %q", got)
	}
	if got := defaultString("A2O_AGENT_NAME", "", "local-agent"); got != "public-agent" {
		t.Fatalf("agent name env = %q", got)
	}
	if got := defaultString("A2O_AGENT_PROJECT_KEY", "", envDefault("A2O_PROJECT_KEY", "")); got != "portal" {
		t.Fatalf("agent project env = %q", got)
	}
	if got := envDuration("A2O_AGENT_POLL_INTERVAL", 0); got.String() != "3s" {
		t.Fatalf("poll interval env = %s", got)
	}
	if got := envInt("A2O_AGENT_MAX_ITERATIONS", 0); got != 4 {
		t.Fatalf("max iterations env = %d", got)
	}
}

func TestRemovedA3AgentEnvironmentRequiresMigration(t *testing.T) {
	t.Setenv("A3_AGENT_CONFIG", "/tmp/legacy-profile.json")
	err := validateRemovedA3AgentEnvironment()
	if err == nil || !strings.Contains(err.Error(), "migration_required=true replacement=environment variable A2O_AGENT_CONFIG") {
		t.Fatalf("expected migration error, got %v", err)
	}
}

func TestWorkerErrorCategoryPrioritizesVerificationFailuresOverDirtyWords(t *testing.T) {
	if got := errorpolicy.WorkerCategory(
		"verification failed because lint found an untracked generated file",
		"exit 1 due to untracked generated file",
		"verification",
	); got != "verification_failed" {
		t.Fatalf("workerErrorCategory() = %q, want verification_failed", got)
	}
}

func TestWorkerErrorCategoryKeepsPublishWorkspaceDirtinessAsWorkspaceDirty(t *testing.T) {
	if got := errorpolicy.WorkerCategory(
		"slot app has changes but is not an edit target: [README.md]",
		"slot app has changes but is not an edit target: [README.md]",
		"verification",
	); got != "workspace_dirty" {
		t.Fatalf("workerErrorCategory() = %q, want workspace_dirty", got)
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
	workspace := filepath.Join(tmp, "workspace")
	if err := os.MkdirAll(workspace, 0o755); err != nil {
		t.Fatal(err)
	}
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
[ "$3" = "$A2O_ROOT_DIR" ]
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
      "command": ["` + scriptPath + `", "` + promptPath + `", "{{result_path}}", "{{a2o_root_dir}}"],
      "env": {}
    },
    "phase_profiles": {}
  }
}`
	if err := os.WriteFile(launcherPath, []byte(launcher), 0o644); err != nil {
		t.Fatal(err)
	}

	t.Setenv("A2O_WORKER_REQUEST_PATH", requestPath)
	t.Setenv("A2O_WORKER_RESULT_PATH", resultPath)
	t.Setenv("A2O_ROOT_DIR", tmp)
	t.Setenv("A2O_ROOT_DIR", tmp)
	t.Setenv("A2O_WORKSPACE_ROOT", workspace)
	t.Setenv("A2O_WORKER_LAUNCHER_CONFIG_PATH", launcherPath)

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

func TestRunWorkerStdinBundleRetriesInvalidWorkerResult(t *testing.T) {
	tmp := t.TempDir()
	workspace := filepath.Join(tmp, "workspace")
	if err := os.MkdirAll(workspace, 0o755); err != nil {
		t.Fatal(err)
	}
	requestPath := filepath.Join(tmp, "request.json")
	resultPath := filepath.Join(tmp, "result.json")
	launcherPath := filepath.Join(tmp, "launcher.json")
	scriptPath := filepath.Join(tmp, "executor.sh")
	countPath := filepath.Join(tmp, "attempt-count")
	promptDir := filepath.Join(tmp, "prompts")
	if err := os.MkdirAll(promptDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(requestPath, []byte(`{
  "task_ref": "A2O#342",
  "run_ref": "run-1",
  "phase": "implementation",
  "phase_runtime": {},
  "slot_paths": {"repo_alpha": "/tmp/repo-alpha"},
  "task_packet": {"title": "implement"}
}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(scriptPath, []byte(`#!/bin/sh
set -eu
count=0
if [ -f "$2" ]; then
  count="$(cat "$2")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$2"
cat > "$3/prompt-$count.json"
if [ "$count" -eq 1 ]; then
  cat > "$1" <<'JSON'
{
  "task_ref": "A2O#342",
  "run_ref": "run-1",
  "phase": "implementation",
  "success": true,
  "summary": "implemented",
  "failing_command": null,
  "observed_state": null,
  "rework_required": false,
  "changed_files": {"repo_alpha": ["main.go"]}
}
JSON
else
  cat > "$1" <<'JSON'
{
  "task_ref": "A2O#342",
  "run_ref": "run-1",
  "phase": "implementation",
  "success": true,
  "summary": "implemented",
  "failing_command": null,
  "observed_state": null,
  "rework_required": false,
  "changed_files": {"repo_alpha": ["main.go"]},
  "review_disposition": {
    "kind": "completed",
    "slot_scopes": ["repo_alpha"],
    "summary": "clean",
    "description": "self-review clean",
    "finding_key": "clean"
  }
}
JSON
fi
`), 0o755); err != nil {
		t.Fatal(err)
	}
	writeWorkerLauncherForTest(t, launcherPath, []string{scriptPath, "{{result_path}}", countPath, promptDir})

	t.Setenv("A2O_WORKER_REQUEST_PATH", requestPath)
	t.Setenv("A2O_WORKER_RESULT_PATH", resultPath)
	t.Setenv("A2O_ROOT_DIR", tmp)
	t.Setenv("A2O_WORKSPACE_ROOT", workspace)
	t.Setenv("A2O_WORKER_LAUNCHER_CONFIG_PATH", launcherPath)

	if code := run([]string{"worker", "stdin-bundle"}); code != 0 {
		t.Fatalf("worker exit code = %d", code)
	}

	if got := strings.TrimSpace(readFileForTest(t, countPath)); got != "2" {
		t.Fatalf("worker should retry once and accept corrected result, attempts=%s", got)
	}
	prompt := readFileForTest(t, filepath.Join(promptDir, "prompt-2.json"))
	if !strings.Contains(prompt, `"result_correction"`) || !strings.Contains(prompt, `"path": "/review_disposition"`) || !strings.Contains(prompt, `"keyword": "required"`) {
		t.Fatalf("correction prompt should include structured validation errors, got:\n%s", prompt)
	}
	var result map[string]any
	if err := json.Unmarshal([]byte(readFileForTest(t, resultPath)), &result); err != nil {
		t.Fatal(err)
	}
	if result["success"] != true || result["summary"] != "implemented" {
		t.Fatalf("unexpected corrected result: %#v", result)
	}
}

func TestRunWorkerStdinBundleFailsAfterCorrectionRetriesExhausted(t *testing.T) {
	tmp := t.TempDir()
	workspace := filepath.Join(tmp, "workspace")
	if err := os.MkdirAll(workspace, 0o755); err != nil {
		t.Fatal(err)
	}
	requestPath := filepath.Join(tmp, "request.json")
	resultPath := filepath.Join(tmp, "result.json")
	launcherPath := filepath.Join(tmp, "launcher.json")
	scriptPath := filepath.Join(tmp, "executor.sh")
	countPath := filepath.Join(tmp, "attempt-count")
	if err := os.WriteFile(requestPath, []byte(`{
  "task_ref": "A2O#342",
  "run_ref": "run-1",
  "phase": "implementation",
  "phase_runtime": {},
  "slot_paths": {"repo_alpha": "/tmp/repo-alpha"},
  "task_packet": {"title": "implement"}
}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(scriptPath, []byte(`#!/bin/sh
set -eu
count=0
if [ -f "$2" ]; then
  count="$(cat "$2")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$2"
cat > /dev/null
cat > "$1" <<'JSON'
{
  "task_ref": "A2O#342",
  "run_ref": "run-1",
  "phase": "implementation",
  "success": true,
  "summary": "implemented",
  "failing_command": null,
  "observed_state": null,
  "rework_required": false,
  "changed_files": {"repo_alpha": ["main.go"]}
}
JSON
`), 0o755); err != nil {
		t.Fatal(err)
	}
	writeWorkerLauncherForTest(t, launcherPath, []string{scriptPath, "{{result_path}}", countPath})

	t.Setenv("A2O_WORKER_REQUEST_PATH", requestPath)
	t.Setenv("A2O_WORKER_RESULT_PATH", resultPath)
	t.Setenv("A2O_ROOT_DIR", tmp)
	t.Setenv("A2O_WORKSPACE_ROOT", workspace)
	t.Setenv("A2O_WORKER_LAUNCHER_CONFIG_PATH", launcherPath)

	if code := run([]string{"worker", "stdin-bundle"}); code != 0 {
		t.Fatalf("worker should return protocol failure payload with exit 0, got %d", code)
	}

	if got := strings.TrimSpace(readFileForTest(t, countPath)); got != "3" {
		t.Fatalf("worker should run initial attempt plus two corrections, attempts=%s", got)
	}
	var result map[string]any
	if err := json.Unmarshal([]byte(readFileForTest(t, resultPath)), &result); err != nil {
		t.Fatal(err)
	}
	if result["success"] != false || result["observed_state"] != "invalid_worker_result" {
		t.Fatalf("unexpected exhausted retry result: %#v", result)
	}
	diagnostics := result["diagnostics"].(map[string]any)
	if diagnostics["correction_attempts"].(float64) != float64(maxWorkerResultCorrectionAttempts) {
		t.Fatalf("diagnostics should report correction attempts: %#v", diagnostics)
	}
	validationErrors := diagnostics["validation_errors"].([]any)
	first := validationErrors[0].(map[string]any)
	if first["path"] != "/review_disposition" || first["keyword"] != "required" {
		t.Fatalf("diagnostics should preserve structured validation errors: %#v", validationErrors)
	}
	salvage := diagnostics["invalid_worker_result_salvage"].(map[string]any)
	if salvage["schema_name"] != "a2o-worker-response" || salvage["artifact_relative_path"] == "" {
		t.Fatalf("diagnostics should point to invalid worker result salvage: %#v", salvage)
	}
	var salvageBody map[string]any
	if err := json.Unmarshal([]byte(readFileForTest(t, stringValue(salvage["artifact_path"]))), &salvageBody); err != nil {
		t.Fatal(err)
	}
	if salvageBody["invalid_result_accepted"] != false || salvageBody["parsed_result"] == nil {
		t.Fatalf("salvage should retain parsed invalid result without accepting it: %#v", salvageBody)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(resultPath), "invalid-worker-results", "latest.json")); err != nil {
		t.Fatalf("latest salvage pointer should exist: %v", err)
	}
}

func TestRunWorkerStdinBundlePreservesRawInvalidJSONAfterRetriesExhausted(t *testing.T) {
	tmp := t.TempDir()
	workspace := filepath.Join(tmp, "workspace")
	if err := os.MkdirAll(workspace, 0o755); err != nil {
		t.Fatal(err)
	}
	requestPath := filepath.Join(tmp, "request.json")
	resultPath := filepath.Join(tmp, "result.json")
	launcherPath := filepath.Join(tmp, "launcher.json")
	scriptPath := filepath.Join(tmp, "executor.sh")
	countPath := filepath.Join(tmp, "attempt-count")
	promptDir := filepath.Join(tmp, "prompts")
	if err := os.MkdirAll(promptDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(requestPath, []byte(`{
  "task_ref": "A2O#342",
  "run_ref": "run-1",
  "phase": "review",
  "phase_runtime": {},
  "task_packet": {"title": "review"}
}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(scriptPath, []byte(`#!/bin/sh
set -eu
count=0
if [ -f "$2" ]; then
  count="$(cat "$2")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$2"
cat > "$3/prompt-$count.json"
printf '{"task_ref":"A2O#342","broken":' > "$1"
`), 0o755); err != nil {
		t.Fatal(err)
	}
	writeWorkerLauncherForTest(t, launcherPath, []string{scriptPath, "{{result_path}}", countPath, promptDir})

	t.Setenv("A2O_WORKER_REQUEST_PATH", requestPath)
	t.Setenv("A2O_WORKER_RESULT_PATH", resultPath)
	t.Setenv("A2O_ROOT_DIR", tmp)
	t.Setenv("A2O_WORKSPACE_ROOT", workspace)
	t.Setenv("A2O_WORKER_LAUNCHER_CONFIG_PATH", launcherPath)

	if code := run([]string{"worker", "stdin-bundle"}); code != 0 {
		t.Fatalf("worker should return protocol failure payload with exit 0, got %d", code)
	}

	if got := strings.TrimSpace(readFileForTest(t, countPath)); got != "3" {
		t.Fatalf("worker should run initial attempt plus two corrections, attempts=%s", got)
	}
	prompt := readFileForTest(t, filepath.Join(promptDir, "prompt-2.json"))
	if !strings.Contains(prompt, `"previous_raw": "{\"task_ref\":\"A2O#342\",\"broken\":"`) {
		t.Fatalf("correction prompt should preserve raw invalid JSON, got:\n%s", prompt)
	}
	var result map[string]any
	if err := json.Unmarshal([]byte(readFileForTest(t, resultPath)), &result); err != nil {
		t.Fatal(err)
	}
	diagnostics := result["diagnostics"].(map[string]any)
	if !strings.Contains(stringValue(diagnostics["worker_response_raw"]), `{"task_ref":"A2O#342","broken":`) {
		t.Fatalf("final diagnostics should preserve raw invalid JSON: %#v", diagnostics)
	}
	validationErrors := diagnostics["validation_errors"].([]any)
	first := validationErrors[0].(map[string]any)
	if first["keyword"] != "type" {
		t.Fatalf("invalid JSON should be reported as type validation error: %#v", validationErrors)
	}
	salvage := diagnostics["invalid_worker_result_salvage"].(map[string]any)
	salvageBody := readFileForTest(t, stringValue(salvage["artifact_path"]))
	if !strings.Contains(salvageBody, `"raw_worker_output": "{\"task_ref\":\"A2O#342\",\"broken\":"`) {
		t.Fatalf("salvage should preserve raw invalid JSON, got:\n%s", salvageBody)
	}
}

func TestRunWorkerStdinBundleIncludesPreviousInvalidWorkerResultSalvage(t *testing.T) {
	tmp := t.TempDir()
	workspace := filepath.Join(tmp, "workspace")
	if err := os.MkdirAll(workspace, 0o755); err != nil {
		t.Fatal(err)
	}
	requestPath := filepath.Join(tmp, "request.json")
	resultPath := filepath.Join(tmp, "result.json")
	launcherPath := filepath.Join(tmp, "launcher.json")
	scriptPath := filepath.Join(tmp, "executor.sh")
	promptPath := filepath.Join(tmp, "prompt.json")
	salvageDir := filepath.Join(filepath.Dir(resultPath), "invalid-worker-results")
	if err := os.MkdirAll(salvageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(requestPath, []byte(`{
  "task_ref": "A2O#343",
  "run_ref": "run-2",
  "phase": "implementation",
  "phase_runtime": {},
  "slot_paths": {"repo_alpha": "/tmp/repo-alpha"},
  "task_packet": {"title": "implement"}
}`), 0o644); err != nil {
		t.Fatal(err)
	}
	writeJSONForTest(t, filepath.Join(salvageDir, "latest.json"), map[string]any{
		"schema_name":            "a2o-worker-response",
		"artifact_relative_path": "invalid-worker-results/A2O-343-run-1-implementation-attempt-03.json",
		"validation_errors": []map[string]any{{
			"path":    "/review_disposition",
			"keyword": "required",
			"message": "review_disposition must be present",
		}},
	})
	if err := os.WriteFile(scriptPath, []byte(`#!/bin/sh
set -eu
cat > "$2"
cat > "$1" <<'JSON'
{
  "task_ref": "A2O#343",
  "run_ref": "run-2",
  "phase": "implementation",
  "success": true,
  "summary": "implemented",
  "failing_command": null,
  "observed_state": null,
  "rework_required": false,
  "changed_files": {"repo_alpha": ["main.go"]},
  "review_disposition": {
    "kind": "completed",
    "slot_scopes": ["repo_alpha"],
    "summary": "clean",
    "description": "self-review clean",
    "finding_key": "clean"
  }
}
JSON
`), 0o755); err != nil {
		t.Fatal(err)
	}
	writeWorkerLauncherForTest(t, launcherPath, []string{scriptPath, "{{result_path}}", promptPath})

	t.Setenv("A2O_WORKER_REQUEST_PATH", requestPath)
	t.Setenv("A2O_WORKER_RESULT_PATH", resultPath)
	t.Setenv("A2O_ROOT_DIR", tmp)
	t.Setenv("A2O_WORKSPACE_ROOT", workspace)
	t.Setenv("A2O_WORKER_LAUNCHER_CONFIG_PATH", launcherPath)

	if code := run([]string{"worker", "stdin-bundle"}); code != 0 {
		t.Fatalf("worker exit code = %d", code)
	}
	prompt := readFileForTest(t, promptPath)
	if !strings.Contains(prompt, `"previous_invalid_worker_result"`) || !strings.Contains(prompt, `"path": "/review_disposition"`) {
		t.Fatalf("worker bundle should include previous invalid result salvage, got:\n%s", prompt)
	}
}

func TestPersistInvalidWorkerResultSalvageRetainsNewestFive(t *testing.T) {
	tmp := t.TempDir()
	resultPath := filepath.Join(tmp, ".a2o", "worker-result.json")
	request := map[string]any{
		"task_ref": "A2O#343",
		"phase":    "implementation",
	}
	for i := 0; i < maxInvalidWorkerResultSalvageArtifacts+2; i++ {
		request["run_ref"] = fmt.Sprintf("run-%d", i)
		if _, err := persistInvalidWorkerResultSalvage(request, resultPath, "/tmp/schema.json", i+1, []workerValidationIssue{{
			Path:    "/review_disposition",
			Keyword: "required",
			Message: "review_disposition must be present",
		}}, map[string]any{"task_ref": "A2O#343"}, "{}", "", ""); err != nil {
			t.Fatal(err)
		}
	}

	salvageDir := filepath.Join(filepath.Dir(resultPath), "invalid-worker-results")
	entries, err := os.ReadDir(salvageDir)
	if err != nil {
		t.Fatal(err)
	}
	artifactCount := 0
	for _, entry := range entries {
		if entry.Name() != "latest.json" && strings.HasSuffix(entry.Name(), ".json") {
			artifactCount++
		}
	}
	if artifactCount != maxInvalidWorkerResultSalvageArtifacts {
		t.Fatalf("expected newest %d salvage artifacts, got %d in %#v", maxInvalidWorkerResultSalvageArtifacts, artifactCount, entries)
	}
	if _, err := os.Stat(filepath.Join(salvageDir, "latest.json")); err != nil {
		t.Fatalf("latest salvage pointer should remain: %v", err)
	}
}

func TestRunWorkerStdinBundleRejectsMissingLauncherConfigEnv(t *testing.T) {
	tmp := t.TempDir()
	requestPath := filepath.Join(tmp, "request.json")
	resultPath := filepath.Join(tmp, "result.json")
	workspace := filepath.Join(tmp, "workspace")
	if err := os.MkdirAll(workspace, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(requestPath, []byte(`{
  "task_ref": "A2O#5",
  "run_ref": "run-1",
  "phase": "implementation",
  "phase_runtime": {},
  "task_packet": {"title": "implement"}
}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tmp, "launcher.json"), []byte(`{"executor": {}}`), 0o644); err != nil {
		t.Fatal(err)
	}

	t.Setenv("A2O_WORKER_REQUEST_PATH", requestPath)
	t.Setenv("A2O_WORKER_RESULT_PATH", resultPath)
	t.Setenv("A2O_ROOT_DIR", tmp)
	t.Setenv("A2O_ROOT_DIR", tmp)
	t.Setenv("A2O_WORKSPACE_ROOT", workspace)

	if code := run([]string{"worker", "stdin-bundle"}); code != 0 {
		t.Fatalf("worker should return protocol failure payload with exit 0, got %d", code)
	}
	resultBody, err := os.ReadFile(resultPath)
	if err != nil {
		t.Fatal(err)
	}
	var result map[string]any
	if err := json.Unmarshal(resultBody, &result); err != nil {
		t.Fatal(err)
	}
	if result["success"] != false || result["observed_state"] != "invalid_executor_config" {
		t.Fatalf("unexpected result: %s", resultBody)
	}
	diagnostics, _ := result["diagnostics"].(map[string]any)
	if !strings.Contains(stringValue(diagnostics["error"]), "A2O_WORKER_LAUNCHER_CONFIG_PATH is required") {
		t.Fatalf("result should explain missing launcher env, got %s", resultBody)
	}
}

func TestRunWorkerStdinBundleWritesAIRawLogWhenConfigured(t *testing.T) {
	tmp := t.TempDir()
	requestPath := filepath.Join(tmp, "request.json")
	resultPath := filepath.Join(tmp, "result.json")
	launcherPath := filepath.Join(tmp, "launcher.json")
	workspace := filepath.Join(tmp, "workspace")
	rawLogRoot := filepath.Join(tmp, "ai-raw-logs")
	if err := os.MkdirAll(workspace, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(requestPath, []byte(`{
  "task_ref": "A2O#7",
  "run_ref": "run-1",
  "phase": "implementation",
  "phase_runtime": {},
  "task_packet": {"title": "implement me"}
}`), 0o644); err != nil {
		t.Fatal(err)
	}
	scriptPath := filepath.Join(tmp, "fake-worker.sh")
	if err := os.WriteFile(scriptPath, []byte(`#!/bin/sh
set -eu
printf 'ai is thinking\n'
cat > "$1" <<'JSON'
{
  "task_ref": "A2O#7",
  "run_ref": "run-1",
  "phase": "implementation",
  "success": true,
  "summary": "implemented",
  "failing_command": null,
  "observed_state": null,
  "rework_required": false,
  "changed_files": {},
  "review_disposition": {
    "kind": "completed",
    "slot_scopes": ["repo_alpha"],
    "summary": "clean",
    "description": "clean",
    "finding_key": "clean"
  }
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
      "command": ["` + scriptPath + `", "{{result_path}}"],
      "env": {}
    },
    "phase_profiles": {}
  }
}`
	if err := os.WriteFile(launcherPath, []byte(launcher), 0o644); err != nil {
		t.Fatal(err)
	}

	t.Setenv("A2O_WORKER_REQUEST_PATH", requestPath)
	t.Setenv("A2O_WORKER_RESULT_PATH", resultPath)
	t.Setenv("A2O_ROOT_DIR", tmp)
	t.Setenv("A2O_WORKSPACE_ROOT", workspace)
	t.Setenv("A2O_WORKER_LAUNCHER_CONFIG_PATH", launcherPath)
	t.Setenv("A2O_AGENT_AI_RAW_LOG_ROOT", rawLogRoot)

	if code := run([]string{"worker", "stdin-bundle"}); code != 0 {
		t.Fatalf("worker exit code = %d", code)
	}

	body, err := os.ReadFile(filepath.Join(rawLogRoot, "A2O-7", "implementation.log"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), "ai is thinking") {
		t.Fatalf("ai raw log missing worker output: %q", string(body))
	}
}

func TestRemovedA3WorkerEnvironmentRequiresMigration(t *testing.T) {
	t.Setenv("A3_WORKER_REQUEST_PATH", "/tmp/legacy-request.json")
	err := validateRemovedA3WorkerEnvironment()
	if err == nil || !strings.Contains(err.Error(), "migration_required=true replacement=environment variable A2O_WORKER_REQUEST_PATH") {
		t.Fatalf("expected migration error, got %v", err)
	}
}

func TestWorkerFailureSanitizesInternalDiagnostics(t *testing.T) {
	payload := workerFailure(
		map[string]any{"task_ref": "A2O#1", "run_ref": "run-1", "phase": "implementation"},
		"failed",
		[]string{"A3_WORKER_REQUEST_PATH=/tmp/request.json", "/usr/local/bin/a3"},
		"executor_failed",
		map[string]any{
			"stderr": "A3_WORKER_REQUEST_PATH /tmp/a3-engine/lib/a3/bootstrap.rb /usr/local/bin/a3 .a2o/workspace.json",
		},
	)
	diagnostics := payload["diagnostics"].(map[string]any)
	failingCommand := payload["failing_command"].(string)
	if strings.Contains(failingCommand, "A3_WORKER_REQUEST_PATH") || strings.Contains(failingCommand, "/usr/local/bin/a3") {
		t.Fatalf("failing command was not sanitized: %s", failingCommand)
	}
	stderr := diagnostics["stderr"].(string)
	for _, forbidden := range []string{"A3_WORKER_REQUEST_PATH", "/tmp/a3-engine", "/usr/local/bin/a3", ".a2o"} {
		if strings.Contains(stderr, forbidden) {
			t.Fatalf("diagnostic still contains %q: %s", forbidden, stderr)
		}
	}
	for _, want := range []string{"A2O_WORKER_REQUEST_PATH", "<runtime-preset-dir>/lib/a2o-internal", "<engine-entrypoint>", "<agent-metadata>"} {
		if !strings.Contains(stderr, want) {
			t.Fatalf("diagnostic missing %q: %s", want, stderr)
		}
	}
}

func TestWorkerResponseSchemaIncludesPhaseSpecificProperties(t *testing.T) {
	tests := []struct {
		name       string
		request    map[string]any
		properties []string
		required   []string
	}{
		{
			name: "implementation",
			request: map[string]any{
				"phase": "implementation",
			},
			properties: []string{"changed_files", "review_disposition", "clarification_request"},
			required:   []string{},
		},
		{
			name: "parent review",
			request: map[string]any{
				"phase": "review",
				"phase_runtime": map[string]any{
					"task_kind": "parent",
				},
			},
			properties: []string{"review_disposition", "clarification_request"},
			required:   []string{},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			path, cleanup, err := writeWorkerResponseSchema(tc.request)
			if err != nil {
				t.Fatal(err)
			}
			defer cleanup()
			body, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			var schema map[string]any
			if err := json.Unmarshal(body, &schema); err != nil {
				t.Fatal(err)
			}
			properties, ok := schema["properties"].(map[string]any)
			if !ok {
				t.Fatalf("schema properties missing: %s", body)
			}
			required := stringSet(schema["required"].([]any))
			for _, property := range tc.properties {
				if _, ok := properties[property]; !ok {
					t.Fatalf("schema missing property %q: %s", property, body)
				}
			}
			for _, property := range tc.required {
				if !required[property] {
					t.Fatalf("schema should require %q: %s", property, body)
				}
			}
			for _, property := range []string{"failing_command", "observed_state"} {
				if required[property] {
					t.Fatalf("schema should not require %q when clarification_request can replace failure diagnostics: %s", property, body)
				}
			}
			if reviewDisposition, ok := properties["review_disposition"].(map[string]any); ok {
				dispositionRequired := stringSet(reviewDisposition["required"].([]any))
				if dispositionRequired["finding_key"] {
					t.Fatalf("review_disposition schema should not require finding_key for clean completed reviews: %s", body)
				}
				dispositionProperties := reviewDisposition["properties"].(map[string]any)
				findingKeyType := dispositionProperties["finding_key"].(map[string]any)["type"].([]any)
				findingKeyTypes := stringSet(findingKeyType)
				if !findingKeyTypes["string"] || !findingKeyTypes["null"] {
					t.Fatalf("review_disposition.finding_key schema should allow string or null: %s", body)
				}
			}
		})
	}
}

func TestWorkerBundleIncludesParentReviewExamples(t *testing.T) {
	tmp := t.TempDir()
	requestPath := filepath.Join(tmp, "request.json")
	request := map[string]any{
		"task_ref": "A2O#42",
		"run_ref":  "run-parent-review-1",
		"phase":    "review",
		"phase_runtime": map[string]any{
			"task_kind": "parent",
		},
		"slot_paths": map[string]any{
			"repo_alpha": filepath.Join(tmp, "repo-alpha"),
		},
	}
	writeJSONForTest(t, requestPath, request)
	t.Setenv("A2O_WORKER_REQUEST_PATH", requestPath)

	var bundle map[string]any
	if err := json.Unmarshal([]byte(workerBundle(nil)), &bundle); err != nil {
		t.Fatal(err)
	}
	contract := bundle["response_contract"].(map[string]any)
	notes := strings.Join(anyStrings(contract["notes"].([]any)), "\n")
	if !strings.Contains(notes, "Copy task_ref, run_ref, and phase exactly") {
		t.Fatalf("parent review notes should explain identity copying: %s", notes)
	}
	examples := contract["examples"].([]any)
	if len(examples) != 3 {
		t.Fatalf("expected three parent review examples, got %#v", examples)
	}
	followUp := examples[1].(map[string]any)["response"].(map[string]any)
	if followUp["success"] != false || followUp["observed_state"] != "review_findings" {
		t.Fatalf("follow-up example should include failure diagnostics: %#v", followUp)
	}
	disposition := followUp["review_disposition"].(map[string]any)
	if disposition["kind"] != "follow_up_child" || !reflect.DeepEqual(disposition["slot_scopes"], []any{"repo_alpha"}) {
		t.Fatalf("unexpected follow-up disposition example: %#v", disposition)
	}
}

func TestWorkerPayloadRequiresReviewDispositionOnlyForImplementationSuccess(t *testing.T) {
	request := map[string]any{
		"task_ref":   "A2O#7",
		"run_ref":    "run-1",
		"phase":      "implementation",
		"slot_paths": map[string]any{"repo_alpha": "/tmp/repo-alpha"},
	}
	failedPayload := map[string]any{
		"task_ref":        "A2O#7",
		"run_ref":         "run-1",
		"phase":           "implementation",
		"success":         false,
		"summary":         "implementation failed",
		"failing_command": "go test ./...",
		"observed_state":  "tests failed",
		"rework_required": false,
	}
	if errors := validateWorkerPayload(failedPayload, request); len(errors) != 0 {
		t.Fatalf("implementation failure should not require review_disposition: %#v", errors)
	}

	successPayload := map[string]any{
		"task_ref":        "A2O#7",
		"run_ref":         "run-1",
		"phase":           "implementation",
		"success":         true,
		"summary":         "implemented",
		"failing_command": nil,
		"observed_state":  nil,
		"rework_required": false,
		"changed_files":   map[string]any{"repo_alpha": []any{"main.go"}},
	}
	errors := validateWorkerPayload(successPayload, request)
	if !containsString(errors, "review_disposition must be present for implementation success") {
		t.Fatalf("implementation success should require review_disposition, got %#v", errors)
	}
}

func TestWorkerPayloadAcceptsClarificationRequestWithoutFailureDiagnostics(t *testing.T) {
	request := map[string]any{
		"task_ref": "A2O#7",
		"run_ref":  "run-1",
		"phase":    "review",
	}
	payload := map[string]any{
		"task_ref":        "A2O#7",
		"run_ref":         "run-1",
		"phase":           "review",
		"success":         false,
		"summary":         "requirement conflict",
		"rework_required": false,
		"clarification_request": map[string]any{
			"question":           "Which behavior should win?",
			"context":            "The request conflicts with the permission model.",
			"options":            []any{"Change permissions", "Keep current behavior"},
			"recommended_option": "Keep current behavior",
			"impact":             "The task waits for requester input.",
		},
	}
	if errors := validateWorkerPayload(payload, request); len(errors) != 0 {
		t.Fatalf("clarification request should be valid, got %#v", errors)
	}
}

func TestWorkerPayloadAcceptsParentReviewClarificationWithoutReviewDisposition(t *testing.T) {
	request := map[string]any{
		"task_ref": "A2O#7",
		"run_ref":  "run-1",
		"phase":    "review",
		"phase_runtime": map[string]any{
			"task_kind": "parent",
		},
	}
	payload := map[string]any{
		"task_ref":        "A2O#7",
		"run_ref":         "run-1",
		"phase":           "review",
		"success":         false,
		"summary":         "parent review needs requester input",
		"rework_required": false,
		"clarification_request": map[string]any{
			"question": "Which child boundary should be used?",
			"context":  "Both decompositions are plausible.",
		},
	}
	if errors := validateWorkerPayload(payload, request); len(errors) != 0 {
		t.Fatalf("parent review clarification request should be valid, got %#v", errors)
	}
}

func TestWorkerPayloadValidatesOptionalReviewDispositionWhenPresent(t *testing.T) {
	request := map[string]any{
		"task_ref": "A2O#7",
		"run_ref":  "run-1",
		"phase":    "review",
		"phase_runtime": map[string]any{
			"task_kind": "parent",
		},
		"slot_paths": map[string]any{"repo_alpha": "/tmp/repo-alpha"},
	}
	payload := map[string]any{
		"task_ref":        "A2O#7",
		"run_ref":         "run-1",
		"phase":           "review",
		"success":         false,
		"summary":         "parent review needs requester input",
		"rework_required": false,
		"clarification_request": map[string]any{
			"question": "Which behavior should win?",
		},
		"review_disposition": map[string]any{
			"kind":        "follow_up_child",
			"slot_scopes": []any{"repo_alpha"},
			"summary":     "missing assertion",
			"description": "A follow-up child would need a stable finding key.",
		},
	}

	errors := validateWorkerPayload(payload, request)
	if !containsString(errors, "review_disposition.finding_key must be a non-empty string for follow_up_child or blocked") {
		t.Fatalf("optional review_disposition should still be validated when present, got %#v", errors)
	}
}

func TestWorkerPayloadNormalizesParentReviewSuccessWithoutReviewDisposition(t *testing.T) {
	request := map[string]any{
		"task_ref": "A2O#7",
		"run_ref":  "run-1",
		"phase":    "review",
		"phase_runtime": map[string]any{
			"task_kind": "parent",
		},
		"slot_paths": map[string]any{"repo_alpha": "/tmp/repo-alpha"},
	}
	payload := map[string]any{
		"task_ref":        "A2O#7",
		"run_ref":         "run-1",
		"phase":           "review",
		"success":         true,
		"summary":         "parent review clean",
		"rework_required": false,
	}

	normalizeReviewDisposition(payload, request)
	if errors := validateWorkerPayload(payload, request); len(errors) != 0 {
		t.Fatalf("parent review success without disposition should be normalized, got %#v", errors)
	}
	disposition := payload["review_disposition"].(map[string]any)
	expected := map[string]any{
		"kind":        "completed",
		"slot_scopes": []string{"repo_alpha"},
		"summary":     "parent review clean",
		"description": "parent review clean",
	}
	if !reflect.DeepEqual(disposition, expected) {
		t.Fatalf("unexpected normalized disposition: %#v", disposition)
	}
}

func TestWorkerPayloadCompletesIncompleteParentReviewSuccessDisposition(t *testing.T) {
	request := map[string]any{
		"task_ref": "A2O#7",
		"run_ref":  "run-1",
		"phase":    "review",
		"phase_runtime": map[string]any{
			"task_kind": "parent",
		},
		"slot_paths": map[string]any{"repo_alpha": "/tmp/repo-alpha"},
	}
	payload := map[string]any{
		"task_ref":        "A2O#7",
		"run_ref":         "run-1",
		"phase":           "review",
		"success":         true,
		"summary":         "parent review clean",
		"rework_required": false,
		"review_disposition": map[string]any{
			"kind":        "completed",
			"slot_scopes": []string{"repo_alpha"},
		},
	}

	normalizeReviewDisposition(payload, request)
	if errors := validateWorkerPayload(payload, request); len(errors) != 0 {
		t.Fatalf("incomplete parent review success disposition should be completed, got %#v", errors)
	}
	disposition := payload["review_disposition"].(map[string]any)
	if disposition["summary"] != "parent review clean" || disposition["description"] != "parent review clean" {
		t.Fatalf("missing normalized parent review fields: %#v", disposition)
	}
	if _, ok := disposition["finding_key"]; ok {
		t.Fatalf("clean parent review normalization should not inject finding_key: %#v", disposition)
	}
}

func TestWorkerPayloadCanonicalizesIdentityBeforeValidation(t *testing.T) {
	request := map[string]any{
		"task_ref": "A2O#7",
		"run_ref":  "run-1",
		"phase":    "review",
		"phase_runtime": map[string]any{
			"task_kind": "parent",
		},
		"slot_paths": map[string]any{"repo_alpha": "/tmp/repo-alpha"},
	}
	payload := map[string]any{
		"task_ref":        "wrong-task",
		"run_ref":         "ProjectName-10-parent",
		"phase":           "wrong-phase",
		"success":         true,
		"summary":         "parent review clean",
		"failing_command": nil,
		"observed_state":  nil,
		"rework_required": false,
		"review_disposition": map[string]any{
			"kind":        "completed",
			"slot_scopes": []string{"repo_alpha"},
			"summary":     "No findings",
			"description": "The parent integration branch is ready.",
			"finding_key": "no-findings",
		},
	}

	canonicalizeWorkerIdentity(payload, request)
	if errors := validateWorkerPayload(payload, request); len(errors) != 0 {
		t.Fatalf("canonicalized parent review payload should be valid, got %#v", errors)
	}
	if payload["task_ref"] != "A2O#7" || payload["run_ref"] != "run-1" || payload["phase"] != "review" {
		t.Fatalf("identity fields were not canonicalized: %#v", payload)
	}
	diagnostics := payload["diagnostics"].(map[string]any)
	corrections := diagnostics["canonicalized_identity"].(map[string]any)
	runRef := corrections["run_ref"].(map[string]any)
	if runRef["provided"] != "ProjectName-10-parent" || runRef["canonical"] != "run-1" {
		t.Fatalf("missing run_ref correction: %#v", corrections)
	}
}

func TestWorkerPayloadRejectsInvalidParentReviewDisposition(t *testing.T) {
	request := map[string]any{
		"task_ref": "A2O#7",
		"run_ref":  "run-1",
		"phase":    "review",
		"phase_runtime": map[string]any{
			"task_kind": "parent",
		},
		"slot_paths": map[string]any{"repo_alpha": "/tmp/repo-alpha"},
	}
	basePayload := map[string]any{
		"task_ref":        "A2O#7",
		"run_ref":         "run-1",
		"phase":           "review",
		"success":         true,
		"summary":         "parent review clean",
		"failing_command": nil,
		"observed_state":  nil,
		"rework_required": false,
		"review_disposition": map[string]any{
			"kind":        "completed",
			"slot_scopes": []string{"repo_alpha"},
			"summary":     "No findings",
			"description": "The parent integration branch is ready.",
			"finding_key": "no-findings",
		},
	}
	tests := []struct {
		name     string
		mutate   func(map[string]any)
		expected string
	}{
		{
			name: "success follow-up child",
			mutate: func(payload map[string]any) {
				payload["review_disposition"].(map[string]any)["kind"] = "follow_up_child"
			},
			expected: "review_disposition.kind must be completed when success is true for parent review",
		},
		{
			name: "legacy repo_scope",
			mutate: func(payload map[string]any) {
				payload["review_disposition"].(map[string]any)["repo_scope"] = "repo_alpha"
			},
			expected: "review_disposition.repo_scope is not supported; use review_disposition.slot_scopes",
		},
		{
			name: "invalid kind",
			mutate: func(payload map[string]any) {
				payload["review_disposition"].(map[string]any)["kind"] = "done"
			},
			expected: "review_disposition.kind must be one of completed, follow_up_child, blocked",
		},
		{
			name: "invalid slot scopes",
			mutate: func(payload map[string]any) {
				payload["review_disposition"].(map[string]any)["slot_scopes"] = []any{"repo_beta"}
			},
			expected: "review_disposition.slot_scopes must be one of repo_alpha, unresolved",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			payload := cloneMap(basePayload)
			payload["review_disposition"] = cloneMap(basePayload["review_disposition"].(map[string]any))
			tc.mutate(payload)
			errors := validateWorkerPayload(payload, request)
			if !containsString(errors, tc.expected) {
				t.Fatalf("expected %q in %#v", tc.expected, errors)
			}
		})
	}
}

func TestWorkerPayloadValidatorMatchesSharedProtocolFixtures(t *testing.T) {
	for _, tc := range loadSharedWorkerProtocolCases(t) {
		t.Run(tc.Name, func(t *testing.T) {
			errors := validateWorkerPayload(tc.Result, tc.Request)
			if tc.Valid {
				if len(errors) != 0 {
					t.Fatalf("expected valid shared protocol fixture, got %#v", errors)
				}
				return
			}
			for _, expected := range tc.ExpectedErrors {
				if !containsString(errors, expected) {
					t.Fatalf("expected %q in %#v", expected, errors)
				}
			}
		})
	}
}

func stringSet(values []any) map[string]bool {
	result := map[string]bool{}
	for _, value := range values {
		if text, ok := value.(string); ok {
			result[text] = true
		}
	}
	return result
}

func anyStrings(values []any) []string {
	result := []string{}
	for _, value := range values {
		if text, ok := value.(string); ok {
			result = append(result, text)
		}
	}
	return result
}

func cloneMap(values map[string]any) map[string]any {
	copied := map[string]any{}
	for key, value := range values {
		copied[key] = value
	}
	return copied
}

type sharedWorkerProtocolCase struct {
	Name           string         `json:"name"`
	Valid          bool           `json:"valid"`
	ExpectedErrors []string       `json:"expected_errors"`
	Request        map[string]any `json:"request"`
	Result         map[string]any `json:"result"`
}

func loadSharedWorkerProtocolCases(t *testing.T) []sharedWorkerProtocolCase {
	t.Helper()
	path := filepath.Join("..", "..", "..", "test", "fixtures", "worker_protocol", "cases.json")
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var cases []sharedWorkerProtocolCase
	if err := json.Unmarshal(body, &cases); err != nil {
		t.Fatal(err)
	}
	return cases
}

func writeJSONForTest(t *testing.T, path string, payload any) {
	t.Helper()
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatal(err)
	}
}

func writeWorkerLauncherForTest(t *testing.T, path string, command []string) {
	t.Helper()
	body, err := json.Marshal(map[string]any{
		"executor": map[string]any{
			"kind":             "command",
			"prompt_transport": "stdin-bundle",
			"result":           map[string]any{"mode": "file"},
			"schema":           map[string]any{"mode": "file"},
			"default_profile": map[string]any{
				"command": command,
				"env":     map[string]any{},
			},
			"phase_profiles": map[string]any{},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatal(err)
	}
}

func readFileForTest(t *testing.T, path string) string {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
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
