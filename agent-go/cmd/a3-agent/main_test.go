package main

import (
	"encoding/json"
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

func TestPublicAgentEnvironmentAliasesTakePrecedence(t *testing.T) {
	t.Setenv("A2O_AGENT_CONFIG", "/tmp/public-profile.json")
	t.Setenv("A3_AGENT_CONFIG", "/tmp/legacy-profile.json")
	t.Setenv("A2O_AGENT_NAME", "public-agent")
	t.Setenv("A3_AGENT_NAME", "legacy-agent")
	t.Setenv("A2O_AGENT_POLL_INTERVAL", "3s")
	t.Setenv("A3_AGENT_POLL_INTERVAL", "9s")
	t.Setenv("A2O_AGENT_MAX_ITERATIONS", "4")
	t.Setenv("A3_AGENT_MAX_ITERATIONS", "8")

	if got := preScanConfigPath(nil); got != "/tmp/public-profile.json" {
		t.Fatalf("preScanConfigPath env = %q", got)
	}
	if got := defaultStringCompat("A2O_AGENT_NAME", "A3_AGENT_NAME", "", "local-agent"); got != "public-agent" {
		t.Fatalf("agent name alias = %q", got)
	}
	if got := envDurationCompat("A2O_AGENT_POLL_INTERVAL", "A3_AGENT_POLL_INTERVAL", 0); got.String() != "3s" {
		t.Fatalf("poll interval alias = %s", got)
	}
	if got := envIntCompat("A2O_AGENT_MAX_ITERATIONS", "A3_AGENT_MAX_ITERATIONS", 0); got != 4 {
		t.Fatalf("max iterations alias = %d", got)
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
    "repo_scope": "repo_alpha",
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

func TestWorkerEnvCompatFallsBackToLegacyNames(t *testing.T) {
	t.Setenv("A3_WORKER_REQUEST_PATH", "/tmp/legacy-request.json")
	if got := envCompat("A2O_WORKER_REQUEST_PATH", "A3_WORKER_REQUEST_PATH"); got != "/tmp/legacy-request.json" {
		t.Fatalf("legacy fallback = %q", got)
	}
	t.Setenv("A2O_WORKER_REQUEST_PATH", "/tmp/public-request.json")
	if got := envCompat("A2O_WORKER_REQUEST_PATH", "A3_WORKER_REQUEST_PATH"); got != "/tmp/public-request.json" {
		t.Fatalf("public env should win, got %q", got)
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
	}{
		{
			name: "implementation",
			request: map[string]any{
				"phase": "implementation",
			},
			properties: []string{"changed_files", "review_disposition"},
		},
		{
			name: "parent review",
			request: map[string]any{
				"phase": "review",
				"phase_runtime": map[string]any{
					"task_kind": "parent",
				},
			},
			properties: []string{"review_disposition"},
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
				if !required[property] {
					t.Fatalf("schema should require %q: %s", property, body)
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
