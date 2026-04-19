package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestAgentTargetPrintsSupportedTarget(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{"agent", "target"}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}

	target := strings.TrimSpace(stdout.String())
	if !strings.Contains(target, "-") {
		t.Fatalf("target should include os-arch, got %q", target)
	}
}

func TestClassifyUserFacingError(t *testing.T) {
	tests := []struct {
		name     string
		message  string
		category string
	}{
		{
			name:     "project config",
			message:  "project.yaml schema is invalid",
			category: "configuration_error",
		},
		{
			name:     "dirty workspace",
			message:  "repo app has changes: README.md",
			category: "workspace_dirty",
		},
		{
			name:     "merge conflict",
			message:  "merge conflict detected in src/main.go",
			category: "merge_conflict",
		},
		{
			name:     "verification",
			message:  "verification command failed",
			category: "verification_failed",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			category, remediation := classifyUserFacingError(tt.message)
			if category != tt.category {
				t.Fatalf("category=%q, want %q", category, tt.category)
			}
			if strings.TrimSpace(remediation) == "" {
				t.Fatalf("remediation should be present")
			}
		})
	}
}

func TestAgentInstallExportsAgentFromRuntimeImage(t *testing.T) {
	tempDir := t.TempDir()
	outputPath := filepath.Join(tempDir, "bin", "a3-agent")
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"agent",
		"install",
		"--target",
		"darwin-amd64",
		"--output",
		outputPath,
		"--compose-project",
		"test-project",
		"--compose-file",
		"compose.yml",
		"--runtime-service",
		"a2o-runtime",
		"--build",
	}, runner, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}

	if !strings.Contains(stdout.String(), "agent_installed target=darwin-amd64") {
		t.Fatalf("stdout should describe installed agent, got %q", stdout.String())
	}
	info, err := os.Stat(outputPath)
	if err != nil {
		t.Fatalf("exported agent missing: %v", err)
	}
	if info.Mode().Perm()&0o111 == 0 {
		t.Fatalf("exported agent should be executable, mode=%s", info.Mode())
	}

	joined := runner.joinedCalls()
	assertCallContains(t, joined, "docker compose -p test-project -f compose.yml build a2o-runtime")
	assertCallContains(t, joined, "docker compose -p test-project -f compose.yml up -d --no-deps a2o-runtime")
	assertCallContains(t, joined, "docker compose -p test-project -f compose.yml ps -q a2o-runtime")
	assertCallContains(t, joined, "docker exec container-123 a3 agent package verify --target darwin-amd64")
	assertCallContains(t, joined, "docker exec container-123 a3 agent package export --target darwin-amd64 --output /tmp/a2o-agent-export")
	assertCallContains(t, joined, "docker cp container-123:/tmp/a2o-agent-export "+outputPath)
}

func TestProjectBootstrapWritesRuntimeInstanceConfig(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "a3-project")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"project",
		"bootstrap",
		"--package",
		packageDir,
		"--workspace",
		tempDir,
		"--compose-project",
		"a3-test",
		"--soloboard-port",
		"3479",
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}

	configPath := filepath.Join(tempDir, ".work", "a2o", "runtime-instance.json")
	body, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatalf("instance config missing: %v", err)
	}
	var config runtimeInstanceConfig
	if err := json.Unmarshal(body, &config); err != nil {
		t.Fatalf("invalid instance config: %v", err)
	}
	if config.PackagePath != packageDir {
		t.Fatalf("PackagePath=%q, want %q", config.PackagePath, packageDir)
	}
	if config.ComposeProject != "a3-test" {
		t.Fatalf("ComposeProject=%q", config.ComposeProject)
	}
	if config.SoloBoardPort != "3479" {
		t.Fatalf("SoloBoardPort=%q", config.SoloBoardPort)
	}
	if config.RuntimeService != "a2o-runtime" {
		t.Fatalf("RuntimeService=%q", config.RuntimeService)
	}
	if config.StorageDir != "/var/lib/a2o/a2o-runtime" {
		t.Fatalf("StorageDir=%q", config.StorageDir)
	}
}

func TestProjectBootstrapDefaultsToProjectPackageDirectory(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "project-package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"project",
		"bootstrap",
		"--workspace",
		tempDir,
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}

	configPath := filepath.Join(tempDir, ".work", "a2o", "runtime-instance.json")
	body, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatalf("instance config missing: %v", err)
	}
	var config runtimeInstanceConfig
	if err := json.Unmarshal(body, &config); err != nil {
		t.Fatalf("invalid instance config: %v", err)
	}
	if config.PackagePath != packageDir {
		t.Fatalf("PackagePath=%q, want %q", config.PackagePath, packageDir)
	}
}

func TestDefaultComposeProjectNameUsesA2OPrefix(t *testing.T) {
	if got := defaultComposeProjectName("/tmp/project-package"); got != "a2o-project-package" {
		t.Fatalf("defaultComposeProjectName=%q", got)
	}
	if got := defaultComposeProjectName("/tmp/a3-project-package"); got != "a2o-project-package" {
		t.Fatalf("defaultComposeProjectName should strip legacy a3 prefix, got %q", got)
	}
}

func TestDefaultBranchNamespaceStripsLegacyA3Prefix(t *testing.T) {
	if got := defaultBranchNamespace("a3-test"); got != "test" {
		t.Fatalf("defaultBranchNamespace=%q", got)
	}
	if got := defaultBranchNamespace("a2o-reference"); got != "a2o-reference" {
		t.Fatalf("defaultBranchNamespace=%q", got)
	}
}

func TestApplyAgentInstallOverridesMapsLegacyRuntimeServiceToA2O(t *testing.T) {
	config := applyAgentInstallOverrides(runtimeInstanceConfig{
		ComposeProject: "a2o-upgraded",
		ComposeFile:    "compose.yml",
		RuntimeService: "a3-runtime",
	}, "", "", "")
	if config.RuntimeService != "a2o-runtime" {
		t.Fatalf("RuntimeService=%q", config.RuntimeService)
	}

	t.Setenv("A3_RUNTIME_SERVICE", "a3-runtime")
	config = applyAgentInstallOverrides(runtimeInstanceConfig{
		ComposeProject: "custom",
		ComposeFile:    "compose.yml",
	}, "", "", "a3-runtime")
	if config.RuntimeService != "a2o-runtime" {
		t.Fatalf("legacy override RuntimeService=%q", config.RuntimeService)
	}
}

func TestRuntimeCommandsReadLegacyInstanceConfig(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeLegacyTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "legacy-project",
		RuntimeService: "a2o-runtime",
		SoloBoardPort:  "3479",
		AgentPort:      "7393",
		StorageDir:     "/var/lib/a3/a2o-runtime",
	})
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"kanban", "url"}, &fakeRunner{}, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	if !strings.Contains(stdout.String(), "http://localhost:3479") {
		t.Fatalf("legacy instance config should be discovered, got %q", stdout.String())
	}

	stdout.Reset()
	stderr.Reset()
	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "status"}, &fakeRunner{}, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("runtime status returned %d, stderr=%s", code, stderr.String())
		}
	})
	if !strings.Contains(stdout.String(), filepath.Join(tempDir, ".work", "a2o", "runtime-instance.json")) {
		t.Fatalf("legacy instance config should be reported as public path, got %q", stdout.String())
	}
	if strings.Contains(stdout.String(), ".a3/runtime-instance.json") || strings.Contains(stderr.String(), ".a3/runtime-instance.json") {
		t.Fatalf("normal output should not expose legacy instance config path, stdout=%q stderr=%q", stdout.String(), stderr.String())
	}
}

func TestProjectTemplatePrintsValidMinimalProjectYaml(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"project",
		"template",
		"--package-name",
		"sample-product",
		"--kanban-project",
		"SampleProduct",
		"--language",
		"node",
		"--executor-bin",
		"a2o-worker",
		"--repo-label",
		"repo:app",
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}

	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "project-package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), stdout.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(stdout.String(), "prompt_transport") || strings.Contains(stdout.String(), "default_profile") || strings.Contains(stdout.String(), "phase_profiles") {
		t.Fatalf("template should use compact executor syntax, got:\n%s", stdout.String())
	}
	if strings.Contains(stdout.String(), "provider: soloboard") {
		t.Fatalf("template should not expose fixed kanban provider, got:\n%s", stdout.String())
	}
	config, err := loadProjectPackageConfig(packageDir)
	if err != nil {
		t.Fatalf("generated project.yaml should load: %v\n%s", err, stdout.String())
	}
	if config.PackageName != "sample-product" {
		t.Fatalf("PackageName=%q", config.PackageName)
	}
	if config.KanbanProject != "SampleProduct" {
		t.Fatalf("KanbanProject=%q", config.KanbanProject)
	}
	if !strings.Contains(stdout.String(), "a2o agent install --target auto --output ./.work/a2o/agent/bin/a2o-agent") {
		t.Fatalf("template should document canonical agent install path, got:\n%s", stdout.String())
	}
	if config.Repos["app"].Label != "repo:app" {
		t.Fatalf("repo label=%q", config.Repos["app"].Label)
	}
	for _, want := range []string{"git", "node", "npm", "a2o-worker"} {
		if !containsString(config.AgentRequiredBins, want) {
			t.Fatalf("required_bins missing %q in %#v", want, config.AgentRequiredBins)
		}
	}
	command := config.Executor["default_profile"].(map[string]any)["command"].([]any)
	if strings.Join([]string{
		command[0].(string),
		command[1].(string),
		command[2].(string),
		command[3].(string),
		command[4].(string),
	}, " ") != "a2o-worker --schema {{schema_path}} --result {{result_path}}" {
		t.Fatalf("unexpected executor command: %#v", command)
	}
}

func TestProjectTemplateWritesOutputFileWithCustomExecutorArgs(t *testing.T) {
	tempDir := t.TempDir()
	outputPath := filepath.Join(tempDir, "project-package", "project.yaml")
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"project",
		"template",
		"--package-name",
		"python-product",
		"--kanban-project",
		"PythonProduct",
		"--language",
		"python",
		"--executor-bin",
		"custom-worker",
		"--executor-arg",
		"run",
		"--executor-arg",
		"--out={{result_path}}",
		"--output",
		outputPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "project_template_written path="+outputPath) {
		t.Fatalf("stdout should describe output path, got %q", stdout.String())
	}
	if strings.Contains(stdout.String(), "kanban_bootstrap_template_written") {
		t.Fatalf("template should not write a separate kanban bootstrap file, got %q", stdout.String())
	}
	body, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatalf("project template missing: %v", err)
	}
	if strings.Contains(string(body), "provider: soloboard") {
		t.Fatalf("template should not expose fixed kanban provider:\n%s", string(body))
	}
	if strings.Contains(string(body), "bootstrap:") || strings.Contains(string(body), "bootstrap.json") {
		t.Fatalf("template should inline kanban bootstrap into project.yaml:\n%s", string(body))
	}
	config, err := loadProjectPackageConfig(filepath.Dir(outputPath))
	if err != nil {
		t.Fatalf("generated project.yaml should load: %v", err)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(outputPath), "kanban", "bootstrap.json")); !os.IsNotExist(err) {
		t.Fatalf("template should not create kanban/bootstrap.json, err=%v", err)
	}
	command := config.Executor["default_profile"].(map[string]any)["command"].([]any)
	if got := command[0].(string) + " " + command[1].(string) + " " + command[2].(string); got != "custom-worker run --out={{result_path}}" {
		t.Fatalf("unexpected executor command: %s", got)
	}
	if !containsString(config.AgentRequiredBins, "python3") {
		t.Fatalf("python template should include python3 in %#v", config.AgentRequiredBins)
	}
}

func TestProjectTemplateRefusesToOverwriteWithoutForce(t *testing.T) {
	tempDir := t.TempDir()
	outputPath := filepath.Join(tempDir, "project-package", "project.yaml")
	if err := os.MkdirAll(filepath.Dir(outputPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(outputPath, []byte("existing\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"project",
		"template",
		"--output",
		outputPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("run should fail when output exists")
	}
	if !strings.Contains(stderr.String(), "pass --force to overwrite") {
		t.Fatalf("stderr should explain force, got %q", stderr.String())
	}
	body, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "existing\n" {
		t.Fatalf("existing file should not be overwritten, got %q", string(body))
	}
}

func TestProjectPackageLoaderExpandsCompactExecutorCommand(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "project-package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: compact-executor
kanban:
  project: CompactExecutor
repos:
  app:
    path: ..
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
          - --result
          - "{{result_path}}"
    review:
      skill: skills/review/default.md
    merge:
      target: merge_to_live
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	config, err := loadProjectPackageConfig(packageDir)
	if err != nil {
		t.Fatalf("compact executor should load: %v", err)
	}
	if config.Executor["kind"] != "command" {
		t.Fatalf("compact executor should expand kind, got %#v", config.Executor)
	}
	if config.Executor["prompt_transport"] != "stdin-bundle" {
		t.Fatalf("compact executor should expand transport, got %#v", config.Executor)
	}
	profile := config.Executor["default_profile"].(map[string]any)
	command := profile["command"].([]any)
	if command[0].(string) != "worker" || command[2].(string) != "{{result_path}}" {
		t.Fatalf("unexpected expanded command: %#v", command)
	}
}

func TestUnsupportedRuntimeCommandsAreNotPublicEntrypoints(t *testing.T) {
	for _, command := range [][]string{
		{"runtime", "command-plan"},
	} {
		var stdout bytes.Buffer
		var stderr bytes.Buffer

		code := run(command, &fakeRunner{}, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run(%v) unexpectedly succeeded", command)
		}
		if !strings.Contains(stderr.String(), "unknown runtime subcommand") {
			t.Fatalf("stderr should reject runtime command, got %q", stderr.String())
		}
		if !strings.Contains(stderr.String(), "a2o runtime run-once") {
			t.Fatalf("stderr should guide to runtime entrypoints, got %q", stderr.String())
		}
	}
}

func TestUsageAdvertisesKanbanAndRuntimeEntrypoints(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{"help"}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}

	output := stdout.String()
	for _, want := range []string{
		"a2o project bootstrap [--package DIR]",
		"a2o kanban up [--build]",
		"a2o kanban doctor",
		"a2o kanban url",
		"a2o runtime up [--build] [--pull]",
		"a2o runtime down",
		"a2o runtime start [--interval DURATION]  # start scheduler",
		"a2o runtime stop                         # stop scheduler",
		"a2o runtime status",
		"a2o runtime image-digest",
		"a2o runtime doctor",
		"a2o runtime describe-task TASK_REF",
		"a2o runtime run-once [--max-steps N] [--agent-attempts N]",
		"a2o runtime loop [--interval DURATION] [--max-cycles N]",
		"a2o agent install [--target auto] [--output PATH] [--build]",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("usage missing %q in %q", want, output)
		}
	}
	for _, hidden := range []string{
		"a2o runtime command-plan",
		"a2o kanban run-once",
		"a2o kanban loop",
		"a2o kanban command-plan",
	} {
		if strings.Contains(output, hidden) {
			t.Fatalf("usage should not advertise %q in %q", hidden, output)
		}
	}
}

func TestGroupHelpPrintsUsage(t *testing.T) {
	for _, group := range []string{"project", "kanban", "runtime", "agent"} {
		t.Run(group, func(t *testing.T) {
			var stdout bytes.Buffer
			var stderr bytes.Buffer

			code := run([]string{group, "--help"}, &fakeRunner{}, &stdout, &stderr)
			if code != 0 {
				t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
			}
			if !strings.Contains(stdout.String(), "a2o "+group+" ") {
				t.Fatalf("%s help should print group usage, got %q", group, stdout.String())
			}
			if strings.Contains(stderr.String(), "unknown "+group+" subcommand") {
				t.Fatalf("%s help should not be an unknown subcommand, got %q", group, stderr.String())
			}
		})
	}
}

func TestSubcommandFlagDiagnosticsUseA2ONames(t *testing.T) {
	for _, tc := range []struct {
		name string
		args []string
		want string
	}{
		{name: "project bootstrap", args: []string{"project", "bootstrap", "-bad"}, want: "Usage of a2o project bootstrap:"},
		{name: "kanban up", args: []string{"kanban", "up", "-bad"}, want: "Usage of a2o kanban up:"},
		{name: "kanban doctor", args: []string{"kanban", "doctor", "-bad"}, want: "Usage of a2o kanban doctor:"},
		{name: "kanban url", args: []string{"kanban", "url", "-bad"}, want: "Usage of a2o kanban url:"},
		{name: "runtime up", args: []string{"runtime", "up", "-bad"}, want: "Usage of a2o runtime up:"},
		{name: "runtime down", args: []string{"runtime", "down", "-bad"}, want: "Usage of a2o runtime down:"},
		{name: "runtime start", args: []string{"runtime", "start", "-bad"}, want: "Usage of a2o runtime start:"},
		{name: "runtime stop", args: []string{"runtime", "stop", "-bad"}, want: "Usage of a2o runtime stop:"},
		{name: "runtime status", args: []string{"runtime", "status", "-bad"}, want: "Usage of a2o runtime status:"},
		{name: "runtime image-digest", args: []string{"runtime", "image-digest", "-bad"}, want: "Usage of a2o runtime image-digest:"},
		{name: "runtime doctor", args: []string{"runtime", "doctor", "-bad"}, want: "Usage of a2o runtime doctor:"},
		{name: "runtime run-once", args: []string{"runtime", "run-once", "-bad"}, want: "Usage of a2o runtime run-once:"},
		{name: "runtime loop", args: []string{"runtime", "loop", "-bad"}, want: "Usage of a2o runtime loop:"},
		{name: "agent install", args: []string{"agent", "install", "-bad"}, want: "Usage of a2o agent install:"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var stdout bytes.Buffer
			var stderr bytes.Buffer

			code := run(tc.args, &fakeRunner{}, &stdout, &stderr)
			if code == 0 {
				t.Fatalf("run unexpectedly succeeded")
			}
			if !strings.Contains(stderr.String(), tc.want) {
				t.Fatalf("stderr should contain %q, got %q", tc.want, stderr.String())
			}
			if strings.Contains(stderr.String(), "Usage of a3 ") {
				t.Fatalf("stderr should not expose internal usage name, got %q", stderr.String())
			}
			if strings.Contains(stderr.String(), "a3-agent") {
				t.Fatalf("stderr should use public agent binary name, got %q", stderr.String())
			}
		})
	}
}

func TestKanbanUpUsesBootstrappedInstanceConfig(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		SoloBoardPort:  "3480",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"kanban", "up", "--build"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	joined := runner.joinedCalls()
	assertCallContains(t, joined, "docker volume inspect a3-test_soloboard-data")
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml build a2o-runtime")
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml up -d a2o-runtime soloboard")
	if !strings.Contains(stdout.String(), "kanban_data compose_project=a3-test volume=a3-test_soloboard-data mode=reuse_existing") {
		t.Fatalf("stdout should describe kanban data volume, got %q", stdout.String())
	}
	if !strings.Contains(stdout.String(), "kanban_up compose_project=a3-test volume=a3-test_soloboard-data url=http://localhost:3480/") {
		t.Fatalf("stdout should describe kanban up, got %q", stdout.String())
	}
}

func TestKanbanUpFreshBoardFailsWhenVolumeExists(t *testing.T) {
	tempDir := t.TempDir()
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    filepath.Join(tempDir, "package"),
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		SoloBoardPort:  "3480",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"kanban", "up", "--fresh-board"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail when fresh board volume exists")
		}
	})

	if !strings.Contains(stderr.String(), "fresh board requested but kanban volume already exists: a3-test_soloboard-data") {
		t.Fatalf("stderr should describe existing volume, got %q", stderr.String())
	}
}

func TestKanbanUpBootstrapsPackageBoard(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "reference", "project-package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	projectYaml := strings.Join([]string{
		"schema_version: 1",
		"package:",
		"  name: reference",
		"kanban:",
		// Older project.yaml files with provider remain loadable for compatibility.
		"  provider: soloboard",
		"  project: A2OReference",
		"  labels:",
		"    - area:reference",
		"repos:",
		"  app:",
		"    path: ..",
		"    label: repo:app",
		"runtime:",
		"  phases:",
		"    implementation:",
		"      executor:",
		"        command:",
		"          - codex",
		"          - exec",
		"    review:",
		"      executor:",
		"        command:",
		"          - codex",
		"          - exec",
		"    merge:",
		"      target: merge_to_live",
		"      policy: ff_only",
		"      target_ref: refs/heads/main",
		"",
	}, "\n")
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(projectYaml), 0o644); err != nil {
		t.Fatal(err)
	}
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		SoloBoardPort:  "3480",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"kanban", "up"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	joined := runner.joinedCalls()
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml up -d a2o-runtime soloboard")
	assertCallContains(t, joined, `docker compose -p a3-test -f compose.yml exec -T a2o-runtime python3 /opt/a2o/share/tools/kanban/bootstrap_soloboard.py --config-json {"boards":[{"name":"A2OReference","tags":[{"name":"area:reference"},{"name":"repo:app"}]}]} --base-url http://soloboard:3000 --board A2OReference`)
	if !strings.Contains(stdout.String(), "kanban_bootstrapped project=A2OReference source=project.yaml") {
		t.Fatalf("stdout should describe kanban bootstrap, got %q", stdout.String())
	}
}

func TestDoctorReportsReleaseReadinessChecks(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	repoDir := filepath.Join(tempDir, "repo")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(repoDir, 0o755); err != nil {
		t.Fatal(err)
	}
	projectYaml := strings.Join([]string{
		"schema_version: 1",
		"package:",
		"  name: sample",
		"kanban:",
		"  project: Sample",
		"repos:",
		"  app:",
		"    path: ../repo",
		"agent:",
		"  required_bins: [\"sh\"]",
		"runtime:",
		"  phases:",
		"    implementation:",
		"      skill: skills/implementation/base.md",
		"      executor:",
		"        command: [\"sh\", \"-c\", \"echo ok\"]",
		"    review:",
		"      skill: skills/review/default.md",
		"    merge:",
		"      target: merge_to_live",
		"      policy: ff_only",
		"      target_ref: refs/heads/main",
		"",
	}, "\n")
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(projectYaml), 0o644); err != nil {
		t.Fatal(err)
	}
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a2o-sample",
		RuntimeService: "a2o-runtime",
		SoloBoardPort:  "3480",
	})
	agentPath := filepath.Join(tempDir, hostAgentBinRelativePath)
	if err := os.MkdirAll(filepath.Dir(agentPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(agentPath, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"doctor"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s stdout=%s", code, stderr.String(), stdout.String())
		}
	})

	for _, want := range []string{
		"doctor_check name=project_package status=ok",
		"doctor_check name=executor_config status=ok detail=commands=sh",
		"doctor_check name=agent_required_command.sh status=ok",
		"doctor_check name=repo_clean.app status=ok detail=" + repoDir,
		"doctor_check name=agent_install status=ok",
		"doctor_check name=kanban_volume status=ok detail=reuse_existing volume=a2o-sample_soloboard-data note=healthy_board_reuse action=none",
		"doctor_check name=kanban_service status=ok detail=http://localhost:3480/",
		"doctor_check name=runtime_container status=ok detail=A2O runtime container=runtime-container",
		"doctor_check name=runtime_image_digest status=ok detail=ghcr.io/wamukat/a2o-engine@sha256:test",
		"doctor_status=ok",
	} {
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("doctor output missing %q in:\n%s", want, stdout.String())
		}
	}
}

func TestDoctorAgentInstallFailureShowsExactOutputPath(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	repoDir := filepath.Join(tempDir, "repo")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(repoDir, 0o755); err != nil {
		t.Fatal(err)
	}
	projectYaml := strings.Join([]string{
		"schema_version: 1",
		"package:",
		"  name: sample",
		"kanban:",
		"  project: Sample",
		"repos:",
		"  app:",
		"    path: ../repo",
		"agent:",
		"  required_bins: [\"sh\"]",
		"runtime:",
		"  phases:",
		"    implementation:",
		"      skill: skills/implementation/base.md",
		"      executor:",
		"        command: [\"sh\", \"-c\", \"echo ok\"]",
		"    review:",
		"      skill: skills/review/default.md",
		"    merge:",
		"      target: merge_to_live",
		"      policy: ff_only",
		"      target_ref: refs/heads/main",
		"",
	}, "\n")
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(projectYaml), 0o644); err != nil {
		t.Fatal(err)
	}
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a2o-sample",
		RuntimeService: "a2o-runtime",
		SoloBoardPort:  "3480",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"doctor"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("doctor should fail when canonical agent is missing, stdout=%s", stdout.String())
		}
	})

	wantPath := filepath.Join(tempDir, hostAgentBinRelativePath)
	wantAction := "action=run a2o agent install --target auto --output " + shellQuote(wantPath)
	if !strings.Contains(stdout.String(), "doctor_check name=agent_install status=blocked") {
		t.Fatalf("doctor should report blocked agent install, got:\n%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), wantAction) {
		t.Fatalf("doctor should include exact install command %q in:\n%s", wantAction, stdout.String())
	}
}

func TestKanbanURLUsesBootstrappedInstanceConfig(t *testing.T) {
	tempDir := t.TempDir()
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion: 1,
		PackagePath:   filepath.Join(tempDir, "package"),
		WorkspaceRoot: tempDir,
		SoloBoardPort: "3480",
	})
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"kanban", "url"}, &fakeRunner{}, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	if strings.TrimSpace(stdout.String()) != "http://localhost:3480/" {
		t.Fatalf("stdout=%q", stdout.String())
	}
}

func TestAgentReadmeUsesKanbanEntrypoints(t *testing.T) {
	body, err := os.ReadFile(filepath.Join("..", "..", "README.md"))
	if err != nil {
		t.Fatalf("read agent README: %v", err)
	}
	content := string(body)
	for _, want := range []string{
		"a2o kanban up",
		"a2o kanban doctor",
	} {
		if !strings.Contains(content, want) {
			t.Fatalf("agent README missing %q", want)
		}
	}
	for _, hidden := range []string{
		"a2o kanban run-once",
		"a2o kanban loop",
		"a2o kanban command-plan",
		"A2O/SoloBoard compose file",
	} {
		if strings.Contains(content, hidden) {
			t.Fatalf("agent README should not advertise %q", hidden)
		}
	}
}

func TestKanbanExecutionCommandsAreNotPublicEntrypoints(t *testing.T) {
	for _, command := range [][]string{
		{"kanban", "run-once"},
		{"kanban", "loop"},
		{"kanban", "command-plan"},
	} {
		var stdout bytes.Buffer
		var stderr bytes.Buffer

		code := run(command, &fakeRunner{}, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run(%v) unexpectedly succeeded", command)
		}
		if !strings.Contains(stderr.String(), "unknown kanban subcommand") {
			t.Fatalf("stderr should reject kanban execution command, got %q", stderr.String())
		}
	}
}

func TestAgentInstallUsesBootstrappedInstanceConfig(t *testing.T) {
	tempDir := t.TempDir()
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    filepath.Join(tempDir, "package"),
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"agent", "install", "--target", "linux-amd64"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	joined := runner.joinedCalls()
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml up -d --no-deps a2o-runtime")
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml ps -q a2o-runtime")
	assertCallContains(t, joined, "docker exec container-123 a3 agent package verify --target linux-amd64")
	assertCallContains(t, joined, "docker cp container-123:/tmp/a2o-agent-export "+filepath.Join(tempDir, hostAgentBinRelativePath))
}

func TestAgentInstallRemovesLegacyRuntimeServiceOrphanBeforeStarting(t *testing.T) {
	tempDir := t.TempDir()
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    filepath.Join(tempDir, "package"),
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a2o-upgrade",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{legacyRuntimeOrphans: []string{"old-runtime-1"}}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"agent", "install", "--target", "linux-amd64"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	joined := runner.joinedCalls()
	assertCallContains(t, joined, "docker ps -a --filter label=com.docker.compose.project=a2o-upgrade --filter label=com.docker.compose.service=a3-runtime --format {{.ID}}")
	assertCallContains(t, joined, "docker rm -f old-runtime-1")
	assertCallContains(t, joined, "docker compose -p a2o-upgrade -f compose.yml up -d --no-deps a2o-runtime")
	if !strings.Contains(stdout.String(), "runtime_orphan_cleanup compose_project=a2o-upgrade service=legacy-runtime containers=old-runtime-1 action=removed") {
		t.Fatalf("stdout should report orphan cleanup, got %q", stdout.String())
	}
}

func TestRuntimeRunOnceUsesBootstrappedInstanceConfig(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		SoloBoardPort:  "3480",
		AgentPort:      "7394",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "run-once", "--max-steps", "1", "--agent-attempts", "2"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	joined := runner.joinedCalls()
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml up -d a2o-runtime soloboard")
	if hasCallPrefix(joined, "bash "+packageDir) {
		t.Fatalf("run-once should not call project runtime script:\n%s", strings.Join(joined, "\n"))
	}
	if !strings.Contains(stdout.String(), "kanban_run_once=generic") {
		t.Fatalf("stdout should describe generic run-once, got %q", stdout.String())
	}
	if !strings.Contains(stdout.String(), "describe_task=a2o runtime describe-task <task-ref>") {
		t.Fatalf("run-once should guide operator to describe-task, got %q", stdout.String())
	}
	if !strings.Contains(strings.Join(joined, "\n"), "a3 execute-until-idle") {
		t.Fatalf("run-once should start execute-until-idle directly, calls:\n%s", strings.Join(joined, "\n"))
	}
	for _, forbidden := range []string{
		"ps -eo pid=,args=",
		"bash -lc cat ",
		"bash -lc echo '--- runtime log tail ---'; tail",
		"a3-engine/bin/a3",
		"a3-engine/lib",
	} {
		if strings.Contains(strings.Join(joined, "\n"), forbidden) {
			t.Fatalf("run-once should use structured cleanup/read/log commands, found %q in:\n%s", forbidden, strings.Join(joined, "\n"))
		}
	}
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml exec -T a2o-runtime pgrep -f a3 execute-until-idle")
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml exec -T a2o-runtime cat /tmp/a2o-runtime-run-once.exit")
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml exec -T a2o-runtime tail -n 160 /tmp/a2o-runtime-run-once.log")
	joinedText := strings.Join(joined, "\n")
	if !strings.Contains(joinedText, "'a3' 'agent-server' '--storage-dir' '/var/lib/a3/test-runtime' '--host' '0.0.0.0' '--port' '7393'") {
		t.Fatalf("agent-server should listen on container-internal port 7393, calls:\n%s", joinedText)
	}
	if !strings.Contains(joinedText, "curl -fsS http://127.0.0.1:7394/v1/agent/jobs/next?agent=probe") {
		t.Fatalf("host readiness probe should use configured host agent port, calls:\n%s", joinedText)
	}
	if !strings.Contains(joinedText, "'--agent-control-plane-url' 'http://127.0.0.1:7393'") {
		t.Fatalf("container execute-until-idle should use internal agent port, calls:\n%s", joinedText)
	}
	if !strings.Contains(joinedText, " -agent host-local -control-plane-url http://127.0.0.1:7394") {
		t.Fatalf("host agent should use configured host agent port, calls:\n%s", joinedText)
	}
	if !strings.Contains(joinedText, "'--worker-command' '"+filepath.Join(tempDir, ".work", "a2o", "agent", "bin", "a2o-agent")+"'") {
		t.Fatalf("run-once should use packaged a2o-agent as worker command, calls:\n%s", joinedText)
	}
	if !strings.Contains(joinedText, "'--worker-command-arg' 'worker'") || !strings.Contains(joinedText, "'--worker-command-arg' 'stdin-bundle'") {
		t.Fatalf("run-once should use built-in a2o-agent stdin-bundle worker, calls:\n%s", joinedText)
	}
	if strings.Contains(strings.Join(joined, "\n"), "portal") {
		t.Fatalf("run-once should not use Portal defaults:\n%s", strings.Join(joined, "\n"))
	}
	for _, want := range []string{
		"'--kanban-project' 'A2OReferenceMultiRepo'",
		"'--agent-source-path' 'repo_alpha=",
		"'--agent-source-path' 'repo_beta=",
		"'--kanban-repo-label' 'repo:catalog=repo_alpha'",
		"'--repo-source' 'repo_alpha=/workspace/repos/catalog-service'",
		"'--preset-dir' '/tmp/a3-engine/config/presets'",
		"'--kanban-command-arg' '/opt/a2o/share/tools/kanban/cli.py'",
	} {
		if !strings.Contains(joinedText, want) {
			t.Fatalf("run-once missing %q in:\n%s", want, joinedText)
		}
	}
	if runner.lastEnv["A3_BUNDLE_COMPOSE_FILE"] != "compose.yml" {
		t.Fatalf("compose env=%q", runner.lastEnv["A3_BUNDLE_COMPOSE_FILE"])
	}
	if runner.lastEnv["A2O_BUNDLE_COMPOSE_FILE"] != "compose.yml" {
		t.Fatalf("public compose env=%q", runner.lastEnv["A2O_BUNDLE_COMPOSE_FILE"])
	}
	if runner.lastEnv["A3_BUNDLE_PROJECT"] != "a3-test" {
		t.Fatalf("project env=%q", runner.lastEnv["A3_BUNDLE_PROJECT"])
	}
	if runner.lastEnv["A2O_BUNDLE_PROJECT"] != "a3-test" {
		t.Fatalf("public project env=%q", runner.lastEnv["A2O_BUNDLE_PROJECT"])
	}
	if runner.lastEnv["A3_RUNTIME_RUN_ONCE_MAX_STEPS"] != "1" {
		t.Fatalf("max steps env=%q", runner.lastEnv["A3_RUNTIME_RUN_ONCE_MAX_STEPS"])
	}
	if runner.lastEnv["A2O_RUNTIME_RUN_ONCE_MAX_STEPS"] != "1" {
		t.Fatalf("public max steps env=%q", runner.lastEnv["A2O_RUNTIME_RUN_ONCE_MAX_STEPS"])
	}
	if runner.lastEnv["A2O_BRANCH_NAMESPACE"] != "test" {
		t.Fatalf("branch namespace env=%q", runner.lastEnv["A2O_BRANCH_NAMESPACE"])
	}
	if runner.lastEnv["A3_HOST_AGENT_BIN"] != filepath.Join(tempDir, ".work", "a2o", "agent", "bin", "a2o-agent") {
		t.Fatalf("agent bin env=%q", runner.lastEnv["A3_HOST_AGENT_BIN"])
	}
}

func TestRuntimeRunOnceRemovesLegacyRuntimeServiceOrphanBeforeStarting(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a2o-upgrade",
		RuntimeService: "a2o-runtime",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{legacyRuntimeOrphans: []string{"old-runtime-1"}}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "run-once", "--max-steps", "1"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	joined := runner.joinedCalls()
	assertCallContains(t, joined, "docker ps -a --filter label=com.docker.compose.project=a2o-upgrade --filter label=com.docker.compose.service=a3-runtime --format {{.ID}}")
	assertCallContains(t, joined, "docker rm -f old-runtime-1")
	assertCallContains(t, joined, "docker compose -p a2o-upgrade -f compose.yml up -d a2o-runtime soloboard")
	if !strings.Contains(stdout.String(), "runtime_orphan_cleanup compose_project=a2o-upgrade service=legacy-runtime containers=old-runtime-1 action=removed") {
		t.Fatalf("stdout should report orphan cleanup, got %q", stdout.String())
	}
}

func TestRuntimeRunOnceFailsWithoutProjectYaml(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "run-once"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail without project.yaml")
		}
	})

	if !strings.Contains(stderr.String(), "project package config not found") {
		t.Fatalf("stderr should mention missing project.yaml, got %q", stderr.String())
	}
	if len(runner.calls) != 0 {
		t.Fatalf("runtime should fail before docker calls, got:\n%s", runner.joinedCalls())
	}
}

func TestRuntimeRunOnceRejectsLegacyManifestSplit(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	if err := os.WriteFile(filepath.Join(packageDir, "manifest.yml"), []byte("presets: [base]\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "run-once"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail when manifest.yml is present")
		}
	})

	if !strings.Contains(stderr.String(), "manifest.yml is no longer supported") {
		t.Fatalf("stderr should reject legacy manifest split, got %q", stderr.String())
	}
	if len(runner.calls) != 0 {
		t.Fatalf("runtime should fail before docker calls, got:\n%s", runner.joinedCalls())
	}
}

func TestRuntimeRunOnceRejectsProjectYamlWithoutSchemaVersion(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "run-once"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail without schema_version")
		}
	})

	if !strings.Contains(stderr.String(), "missing schema_version") {
		t.Fatalf("stderr should mention missing schema_version, got %q", stderr.String())
	}
	if len(runner.calls) != 0 {
		t.Fatalf("runtime should fail before docker calls, got:\n%s", runner.joinedCalls())
	}
}

func TestRuntimeRunOnceRejectsLegacyKanbanBootstrap(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
  bootstrap: kanban/bootstrap.json
repos:
  app:
    path: ..
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    review:
      skill: skills/review/default.md
      executor:
        command:
          - worker
    merge:
      target: merge_to_live
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "run-once"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail with legacy kanban.bootstrap")
		}
	})

	if !strings.Contains(stderr.String(), "invalid kanban.bootstrap") || !strings.Contains(stderr.String(), "kanban.bootstrap is no longer supported") {
		t.Fatalf("stderr should reject legacy kanban.bootstrap, got %q", stderr.String())
	}
	if len(runner.calls) != 0 {
		t.Fatalf("runtime should fail before docker calls, got:\n%s", runner.joinedCalls())
	}
}

func TestRuntimeRunOnceRejectsMalformedProjectExecutor(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - 123
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "run-once"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail with malformed runtime.executor")
		}
	})

	if !strings.Contains(stderr.String(), "invalid runtime.phases") || !strings.Contains(stderr.String(), "implementation.executor.command") {
		t.Fatalf("stderr should mention malformed executor command, got %q", stderr.String())
	}
	if len(runner.calls) != 0 {
		t.Fatalf("runtime should fail before docker calls, got:\n%s", runner.joinedCalls())
	}
}

func TestRuntimeRunOnceRejectsInternalProjectExecutorShape(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  executor:
    kind: command
    prompt_transport: stdin-bundle
    result:
      mode: file
    schema:
      mode: file
    default_profile:
      command:
        - worker
      env: {}
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "run-once"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail with internal runtime.executor shape")
		}
	})

	if !strings.Contains(stderr.String(), "invalid runtime.executor") || !strings.Contains(stderr.String(), "runtime.executor is no longer supported") {
		t.Fatalf("stderr should reject internal executor shape, got %q", stderr.String())
	}
	if len(runner.calls) != 0 {
		t.Fatalf("runtime should fail before docker calls, got:\n%s", runner.joinedCalls())
	}
}

func TestRuntimeRunOnceRejectsEmptyTopLevelProjectExecutor(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  executor: {}
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    review:
      skill: skills/review/default.md
      executor:
        command:
          - worker
    merge:
      target: merge_to_live
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "run-once"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail with empty top-level runtime.executor")
		}
	})

	if !strings.Contains(stderr.String(), "invalid runtime.executor") || !strings.Contains(stderr.String(), "runtime.executor is no longer supported") {
		t.Fatalf("stderr should reject empty top-level executor, got %q", stderr.String())
	}
	if len(runner.calls) != 0 {
		t.Fatalf("runtime should fail before docker calls, got:\n%s", runner.joinedCalls())
	}
}

func TestRuntimeRunOnceRejectsInternalProjectExecutorPhaseProfileShape(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: sample
kanban:
  project: Sample
repos:
  app:
    path: ..
runtime:
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - worker
    review:
      skill: skills/review/default.md
      executor:
        command:
          - review-worker
        prompt_transport: stdin-bundle
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "run-once"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail with internal phase profile shape")
		}
	})

	if !strings.Contains(stderr.String(), "invalid runtime.phases") || !strings.Contains(stderr.String(), "review.executor.prompt_transport is internal") {
		t.Fatalf("stderr should reject internal phase profile shape, got %q", stderr.String())
	}
	if len(runner.calls) != 0 {
		t.Fatalf("runtime should fail before docker calls, got:\n%s", runner.joinedCalls())
	}
}

func TestRuntimeRunOnceRejectsMissingProjectExecutorBeforeDocker(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `schema_version: 1
package:
  name: portal
kanban:
  project: Portal
repos:
  repo_alpha:
    path: ..
runtime:
  live_ref: refs/heads/main
  max_steps: 20
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	t.Setenv("A3_WORKER_LAUNCHER_CONFIG_PATH", filepath.Join(tempDir, "legacy-launcher.json"))

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "run-once"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail without runtime.phases.implementation.executor")
		}
	})

	if !strings.Contains(stderr.String(), "runtime.phases") || !strings.Contains(stderr.String(), "must define implementation") {
		t.Fatalf("stderr should mention missing implementation phase executor, got %q", stderr.String())
	}
	if strings.Contains(stderr.String(), "launcher.json") {
		t.Fatalf("stderr should not ask users for launcher.json, got %q", stderr.String())
	}
	if len(runner.calls) != 0 {
		t.Fatalf("runtime should fail before docker calls, got:\n%s", runner.joinedCalls())
	}
}

func TestRuntimeUpStartsContainersWithoutScheduler(t *testing.T) {
	tempDir := t.TempDir()
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    filepath.Join(tempDir, "package"),
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "up", "--build"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	joined := runner.joinedCalls()
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml build a2o-runtime")
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml up -d a2o-runtime soloboard")
	if strings.Contains(strings.Join(joined, "\n"), "start-background") {
		t.Fatalf("runtime up must not launch scheduler, got:\n%s", strings.Join(joined, "\n"))
	}
	if !strings.Contains(stdout.String(), "runtime_up compose_project=a3-test") {
		t.Fatalf("stdout should report runtime up, got %q", stdout.String())
	}
}

func TestRuntimeUpCanPullConfiguredImageBeforeStarting(t *testing.T) {
	t.Setenv("A2O_RUNTIME_IMAGE", "ghcr.io/wamukat/a2o-engine:latest")
	tempDir := t.TempDir()
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    filepath.Join(tempDir, "package"),
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a2o-pull",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "up", "--pull"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	joined := runner.joinedCalls()
	assertCallContains(t, joined, "docker compose -p a2o-pull -f compose.yml pull a2o-runtime")
	assertCallContains(t, joined, "docker compose -p a2o-pull -f compose.yml up -d a2o-runtime soloboard")
	if runner.lastEnv["A2O_RUNTIME_IMAGE"] != "ghcr.io/wamukat/a2o-engine:latest" {
		t.Fatalf("runtime up should map public A2O_RUNTIME_IMAGE into compose env, got %#v", runner.lastEnv)
	}
}

func TestRuntimeUpRemovesLegacyRuntimeServiceOrphanBeforeStarting(t *testing.T) {
	tempDir := t.TempDir()
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    filepath.Join(tempDir, "package"),
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a2o-upgrade",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{legacyRuntimeOrphans: []string{"old-runtime-1"}}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "up", "--pull"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	joined := runner.joinedCalls()
	assertCallContains(t, joined, "docker ps -a --filter label=com.docker.compose.project=a2o-upgrade --filter label=com.docker.compose.service=a3-runtime --format {{.ID}}")
	assertCallContains(t, joined, "docker rm -f old-runtime-1")
	assertCallContains(t, joined, "docker compose -p a2o-upgrade -f compose.yml up -d a2o-runtime soloboard")
	if strings.Contains(strings.Join(joined, "\n"), " soloboard-data") {
		t.Fatalf("orphan cleanup must not touch kanban volumes, got:\n%s", strings.Join(joined, "\n"))
	}
	if !strings.Contains(stdout.String(), "runtime_orphan_cleanup compose_project=a2o-upgrade service=legacy-runtime containers=old-runtime-1 action=removed") {
		t.Fatalf("stdout should report orphan cleanup, got %q", stdout.String())
	}
}

func TestRuntimeUpReportsSafeRemediationWhenLegacyOrphanRemovalFails(t *testing.T) {
	tempDir := t.TempDir()
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    filepath.Join(tempDir, "package"),
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a2o-upgrade",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{
		legacyRuntimeOrphans: []string{"old-runtime-1", "old-runtime-2"},
		failLegacyRuntimeRM:  true,
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "up", "--pull"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run unexpectedly succeeded, stdout=%s", stdout.String())
		}
	})

	joined := strings.Join(runner.joinedCalls(), "\n")
	if strings.Contains(joined, "docker compose -p a2o-upgrade -f compose.yml up -d a2o-runtime soloboard") {
		t.Fatalf("runtime up must stop before compose up when orphan removal fails, got:\n%s", joined)
	}
	if !strings.Contains(stderr.String(), "safe_remediation='docker' 'rm' '-f' 'old-runtime-1' 'old-runtime-2'") {
		t.Fatalf("stderr should include exact safe remediation, got %q", stderr.String())
	}
}

func TestRuntimeDownStopsContainersWithoutSchedulerMutation(t *testing.T) {
	tempDir := t.TempDir()
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    filepath.Join(tempDir, "package"),
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "down"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	joined := runner.joinedCalls()
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml down")
	if strings.Contains(strings.Join(joined, "\n"), "terminate-process-group") || strings.Contains(strings.Join(joined, "\n"), "start-background") {
		t.Fatalf("runtime down must only affect containers, got:\n%s", strings.Join(joined, "\n"))
	}
	if !strings.Contains(stdout.String(), "runtime_down compose_project=a3-test") {
		t.Fatalf("stdout should report runtime down, got %q", stdout.String())
	}
}

func TestRuntimeStartLaunchesForegroundLoopInBackground(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "start", "--interval", "5s", "--max-steps", "2", "--agent-attempts", "3"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	joined := strings.Join(runner.joinedCalls(), "\n")
	for _, want := range []string{
		"start-background",
		"runtime loop --interval 5s --max-steps 2 --agent-attempts 3",
		filepath.Join(tempDir, ".work", "a2o-runtime", "scheduler.log"),
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("runtime start missing %q in:\n%s", want, joined)
		}
	}
	if !strings.Contains(stdout.String(), "runtime_scheduler_started") {
		t.Fatalf("stdout should report scheduler start, got %q", stdout.String())
	}
	pidBody, err := os.ReadFile(filepath.Join(tempDir, ".work", "a2o-runtime", "scheduler.pid"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(pidBody)) != "12345" {
		t.Fatalf("pid file should contain background pid, got %q", string(pidBody))
	}
	commandBody, err := os.ReadFile(filepath.Join(tempDir, ".work", "a2o-runtime", "scheduler.command"))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(commandBody)); got != runner.processCommands[12345] {
		t.Fatalf("scheduler command file should contain launched command, got %q want %q", got, runner.processCommands[12345])
	}
	if !strings.Contains(stdout.String(), "describe_task=a2o runtime describe-task <task-ref>") {
		t.Fatalf("runtime start should guide operator to describe-task, got %q", stdout.String())
	}
}

func TestRuntimeDescribeTaskAggregatesTaskRunKanbanAndLogHints(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		SoloBoardPort:  "3480",
		AgentPort:      "7394",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "describe-task", "A2O#16"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	output := stdout.String()
	for _, want := range []string{
		"describe_task task_ref=A2O#16",
		"runtime_storage=internal-managed project_config=" + filepath.Join(packageDir, "project.yaml") + " surface_source=project-package",
		"runtime_logs runtime=/tmp/a2o-runtime-run-once.log",
		"task A2O#16 kind=single status=blocked current_run=run-16",
		"run run-16 task=A2O#16 phase=implementation workspace=runtime_workspace source=detached_commit:abc outcome=blocked",
		"evidence workspace=runtime_workspace source=detached_commit:abc",
		"--- kanban_task ---",
		"\"task_ref\":\"A2O#16\"",
		"comment_count=1",
		"comment[0] id=61 updated=2026-04-18T07:46:17.996Z body=blocked evidence is available",
		"operator_logs runtime_log=/tmp/a2o-runtime-run-once.log server_log=/tmp/a2o-runtime-run-once-agent-server.log",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("describe-task missing %q in:\n%s", want, output)
		}
	}
	for _, forbidden := range []string{
		"manifest=",
		"preset_source=",
		"runtime.presets",
	} {
		if strings.Contains(output, forbidden) {
			t.Fatalf("describe-task exposed legacy runtime surface term %q in:\n%s", forbidden, output)
		}
	}

	joined := strings.Join(runner.joinedCalls(), "\n")
	for _, want := range []string{
		"docker compose -p a3-test -f compose.yml exec -T a2o-runtime a3 show-task --storage-backend json --storage-dir /var/lib/a3/test-runtime A2O#16",
		"docker compose -p a3-test -f compose.yml exec -T a2o-runtime a3 show-run --storage-backend json --storage-dir /var/lib/a3/test-runtime --preset-dir /tmp/a3-engine/config/presets run-16 " + filepath.Join(packageDir, "project.yaml"),
		"docker compose -p a3-test -f compose.yml exec -T a2o-runtime python3 /opt/a2o/share/tools/kanban/cli.py --backend soloboard --base-url http://soloboard:3000 task-comment-list --project A2OReferenceMultiRepo --task A2O#16",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("describe-task missing call %q in:\n%s", want, joined)
		}
	}
}

func TestRuntimeDescribeTaskContinuesWhenRuntimeTaskStateIsUnavailable(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		SoloBoardPort:  "3480",
		AgentPort:      "7394",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{failShowTask: true}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "describe-task", "A2O#16"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	output := stdout.String()
	for _, want := range []string{
		"describe_section name=task status=blocked",
		"describe_section name=run_ref status=resolved source=latest_run_store run_ref=run-16",
		"run run-16 task=A2O#16 phase=implementation workspace=runtime_workspace source=detached_commit:abc outcome=blocked",
		"--- kanban_task ---",
		"comment_count=1",
		"operator_logs runtime_log=/tmp/a2o-runtime-run-once.log server_log=/tmp/a2o-runtime-run-once-agent-server.log",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("describe-task missing %q in:\n%s", want, output)
		}
	}
}

func TestRuntimeDescribeTaskFindsLatestRunWhenTaskHasNoCurrentRun(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		SoloBoardPort:  "3480",
		AgentPort:      "7394",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{taskWithoutCurrentRun: true}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "describe-task", "A2O#16"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	output := stdout.String()
	for _, want := range []string{
		"task A2O#16 kind=single status=blocked current_run=",
		"describe_section name=run_ref status=resolved source=latest_run_store run_ref=run-16",
		"run run-16 task=A2O#16 phase=implementation workspace=runtime_workspace source=detached_commit:abc outcome=blocked",
		"evidence workspace=runtime_workspace source=detached_commit:abc",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("describe-task missing %q in:\n%s", want, output)
		}
	}
	if !strings.Contains(strings.Join(runner.joinedCalls(), "\n"), "docker compose -p a3-test -f compose.yml exec -T a2o-runtime ruby -rjson -e") {
		t.Fatalf("describe-task should inspect runs.json, calls:\n%s", strings.Join(runner.joinedCalls(), "\n"))
	}
}

func TestRuntimeStartRejectsInvalidOptionsBeforeBackgroundLaunch(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "start", "--interval", "not-a-duration"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail for invalid interval")
		}
	})

	if strings.Contains(strings.Join(runner.joinedCalls(), "\n"), "start-background") {
		t.Fatalf("runtime start should fail before background launch, got:\n%s", strings.Join(runner.joinedCalls(), "\n"))
	}
	if !strings.Contains(stderr.String(), "parse --interval") {
		t.Fatalf("stderr should mention invalid interval, got %q", stderr.String())
	}
}

func TestRuntimeStartRejectsNegativeIntervalBeforeBackgroundLaunch(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "start", "--interval", "-1s"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail for negative interval")
		}
	})

	if strings.Contains(strings.Join(runner.joinedCalls(), "\n"), "start-background") {
		t.Fatalf("runtime start should fail before background launch, got:\n%s", strings.Join(runner.joinedCalls(), "\n"))
	}
	if !strings.Contains(stderr.String(), "--interval must be >= 0") {
		t.Fatalf("stderr should mention negative interval, got %q", stderr.String())
	}
}

func TestRuntimeStartRequiresProjectConfigBeforeBackgroundLaunch(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "start"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail without project.yaml")
		}
	})

	if !strings.Contains(stderr.String(), "project package config not found") {
		t.Fatalf("stderr should mention missing project.yaml, got %q", stderr.String())
	}
	if strings.Contains(strings.Join(runner.joinedCalls(), "\n"), "start-background") {
		t.Fatalf("runtime start should fail before background launch, got:\n%s", strings.Join(runner.joinedCalls(), "\n"))
	}
}

func TestRuntimeStartRejectsAlreadyRunningScheduler(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	paths := schedulerPaths(runtimeInstanceConfig{WorkspaceRoot: tempDir})
	if err := os.MkdirAll(paths.Dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.PIDFile, []byte("12345\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	command := testSchedulerCommand(t, "runtime", "loop", "--interval", "60s")
	if err := os.WriteFile(paths.CommandFile, []byte(command+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{processCommands: map[int]string{12345: command}}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "start"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail when scheduler is already running")
		}
	})

	if !strings.Contains(stderr.String(), "runtime scheduler already running pid=12345") {
		t.Fatalf("stderr should mention running scheduler, got %q", stderr.String())
	}
	if strings.Contains(strings.Join(runner.joinedCalls(), "\n"), "start-background") {
		t.Fatalf("runtime start should not launch a duplicate scheduler, got:\n%s", strings.Join(runner.joinedCalls(), "\n"))
	}
}

func TestRuntimeStatusReportsRunningScheduler(t *testing.T) {
	t.Setenv("A3_RUNTIME_IMAGE", "ghcr.io/wamukat/a2o-engine@sha256:pinned")
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	paths := schedulerPaths(runtimeInstanceConfig{WorkspaceRoot: tempDir})
	if err := os.MkdirAll(paths.Dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.PIDFile, []byte("12345\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	command := testSchedulerCommand(t, "runtime", "loop", "--interval", "60s")
	if err := os.WriteFile(paths.CommandFile, []byte(command+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{processCommands: map[int]string{12345: command}}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "status"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	if !strings.Contains(stdout.String(), "runtime_scheduler_status=running pid=12345") {
		t.Fatalf("stdout should report running scheduler, got %q", stdout.String())
	}
	for _, want := range []string{
		"runtime_package=" + packageDir,
		"kanban_url=http://localhost:3470/",
		"runtime_status_check name=runtime_container status=running container=runtime-container",
		"runtime_status_check name=kanban_service status=running container=soloboard-container",
		"runtime_image_digest=ghcr.io/wamukat/a2o-engine@sha256:test",
		"runtime_latest_run run_ref=run-16 task_ref=A2O#16 phase=implementation state=terminal outcome=blocked",
	} {
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("stdout should include %q in:\n%s", want, stdout.String())
		}
	}
	assertCallContains(t, runner.joinedCalls(), "process-running 12345")
	assertCallContains(t, runner.joinedCalls(), "process-command 12345")
	if runner.lastEnv["A3_RUNTIME_IMAGE"] != "ghcr.io/wamukat/a2o-engine@sha256:pinned" {
		t.Fatalf("runtime status should evaluate compose with runtime image env, got %#v", runner.lastEnv)
	}
}

func TestRuntimeStatusReportsEmptyHistoryWithoutRubyReadError(t *testing.T) {
	t.Setenv("A2O_RUNTIME_IMAGE", "ghcr.io/wamukat/a2o-engine@sha256:pinned")
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{missingRunHistory: true}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "status"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	output := stdout.String()
	if !strings.Contains(output, "runtime_status_check name=runtime_container status=running container=runtime-container") {
		t.Fatalf("stdout should still report healthy runtime container, got:\n%s", output)
	}
	if !strings.Contains(output, "runtime_status_check name=kanban_service status=running container=soloboard-container") {
		t.Fatalf("stdout should still report healthy kanban service, got:\n%s", output)
	}
	if !strings.Contains(output, "runtime_latest_run status=no_runs reason=history_empty") {
		t.Fatalf("stdout should report empty history normally, got:\n%s", output)
	}
	for _, forbidden := range []string{"rb_sysopen", "No such file or directory", "ruby -rjson"} {
		if strings.Contains(output, forbidden) || strings.Contains(stderr.String(), forbidden) {
			t.Fatalf("status output should not expose low-level missing history detail %q, stdout=%q stderr=%q", forbidden, output, stderr.String())
		}
	}
	if strings.Contains(strings.Join(runner.joinedCalls(), "\n"), " ruby -rjson -e ") {
		t.Fatalf("runtime status should not read missing run history with ruby, calls:\n%s", strings.Join(runner.joinedCalls(), "\n"))
	}
}

func TestRuntimeStatusReportsStaleForUnrelatedReusedPID(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	paths := schedulerPaths(runtimeInstanceConfig{WorkspaceRoot: tempDir})
	if err := os.MkdirAll(paths.Dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.PIDFile, []byte("12345\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	command := testSchedulerCommand(t, "runtime", "loop", "--interval", "60s")
	if err := os.WriteFile(paths.CommandFile, []byte(command+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{processCommands: map[int]string{12345: "sleep 999"}}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "status"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	if !strings.Contains(stdout.String(), "runtime_scheduler_status=stale pid=12345") {
		t.Fatalf("stdout should report stale scheduler, got %q", stdout.String())
	}
	assertCallContains(t, runner.joinedCalls(), "process-running 12345")
	assertCallContains(t, runner.joinedCalls(), "process-command 12345")
}

func TestRuntimeImageDigestPrintsPinnedRuntimeDigest(t *testing.T) {
	t.Setenv("A3_RUNTIME_IMAGE", "ghcr.io/wamukat/a2o-engine@sha256:pinned")
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a2o-digest",
		RuntimeService: "a2o-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "image-digest"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	if !strings.Contains(stdout.String(), "runtime_image_digest=ghcr.io/wamukat/a2o-engine@sha256:test") {
		t.Fatalf("stdout should print digest, got %q", stdout.String())
	}
	if runner.lastEnv["A3_RUNTIME_IMAGE"] != "ghcr.io/wamukat/a2o-engine@sha256:pinned" {
		t.Fatalf("image-digest should evaluate compose with runtime image env, got %#v", runner.lastEnv)
	}
}

func TestRuntimeStatusRejectsInvalidPIDFile(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	paths := schedulerPaths(runtimeInstanceConfig{WorkspaceRoot: tempDir})
	if err := os.MkdirAll(paths.Dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.PIDFile, []byte("not-a-pid\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "status"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail for invalid pid file")
		}
	})

	if !strings.Contains(stderr.String(), "invalid scheduler pid file") {
		t.Fatalf("stderr should mention invalid pid file, got %q", stderr.String())
	}
	if len(runner.calls) != 0 {
		t.Fatalf("invalid pid file should fail before process inspection, got:\n%s", runner.joinedCalls())
	}
}

func TestRuntimeStopKillsSchedulerAndRemovesPID(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	paths := schedulerPaths(runtimeInstanceConfig{WorkspaceRoot: tempDir})
	if err := os.MkdirAll(paths.Dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.PIDFile, []byte("12345\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	command := testSchedulerCommand(t, "runtime", "loop", "--interval", "60s")
	if err := os.WriteFile(paths.CommandFile, []byte(command+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{processCommands: map[int]string{12345: command}}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "stop"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	assertCallContains(t, runner.joinedCalls(), "process-running 12345")
	assertCallContains(t, runner.joinedCalls(), "process-command 12345")
	assertCallContains(t, runner.joinedCalls(), "terminate-process-group 12345")
	if _, err := os.Stat(paths.PIDFile); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("pid file should be removed, stat err=%v", err)
	}
	if _, err := os.Stat(paths.CommandFile); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("command file should be removed, stat err=%v", err)
	}
	if !strings.Contains(stdout.String(), "runtime_scheduler_stopped pid=12345") {
		t.Fatalf("stdout should report scheduler stop, got %q", stdout.String())
	}
}

func TestRuntimeStopDoesNotTerminateUnrelatedReusedPID(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	paths := schedulerPaths(runtimeInstanceConfig{WorkspaceRoot: tempDir})
	if err := os.MkdirAll(paths.Dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.PIDFile, []byte("12345\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	command := testSchedulerCommand(t, "runtime", "loop", "--interval", "60s")
	if err := os.WriteFile(paths.CommandFile, []byte(command+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{processCommands: map[int]string{12345: "/tmp/unrelated runtime loop --interval 60s"}}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "stop"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	if runner.callCount("terminate-process-group 12345") != 0 {
		t.Fatalf("runtime stop must not terminate unrelated process, got:\n%s", strings.Join(runner.joinedCalls(), "\n"))
	}
	assertCallContains(t, runner.joinedCalls(), "docker compose -p a3-test -f compose.yml exec -T a2o-runtime pgrep -f a3 execute-until-idle")
	assertCallContains(t, runner.joinedCalls(), "docker compose -p a3-test -f compose.yml exec -T a2o-runtime pgrep -f a3 agent-server")
	if _, err := os.Stat(paths.PIDFile); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("pid file should be removed after stale stop, stat err=%v", err)
	}
	if _, err := os.Stat(paths.CommandFile); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("command file should be removed after stale stop, stat err=%v", err)
	}
}

func testSchedulerCommand(t *testing.T, args ...string) string {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	return schedulerExpectedCommand(executable, args)
}

func TestRuntimeRunOncePrefersPublicA2OAgentPath(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	publicAgentPath := filepath.Join(tempDir, ".work", "a2o", "agent", "bin", "a2o-agent")
	if err := os.MkdirAll(filepath.Dir(publicAgentPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(publicAgentPath, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		SoloBoardPort:  "3480",
		AgentPort:      "7394",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "run-once"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	if runner.lastEnv["A3_HOST_AGENT_BIN"] != publicAgentPath {
		t.Fatalf("agent bin env=%q, want %q", runner.lastEnv["A3_HOST_AGENT_BIN"], publicAgentPath)
	}
}

func TestRuntimeRunOnceIgnoresLegacyA2OAgentPath(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	legacyAgentPath := filepath.Join(tempDir, ".work", "a2o-agent", "bin", "a2o-agent")
	if err := os.MkdirAll(filepath.Dir(legacyAgentPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(legacyAgentPath, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		SoloBoardPort:  "3480",
		AgentPort:      "7394",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "run-once"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	publicAgentPath := filepath.Join(tempDir, ".work", "a2o", "agent", "bin", "a2o-agent")
	if runner.lastEnv["A3_HOST_AGENT_BIN"] != publicAgentPath {
		t.Fatalf("agent bin env=%q, want canonical %q", runner.lastEnv["A3_HOST_AGENT_BIN"], publicAgentPath)
	}
}

func TestRuntimeRunOnceReadsProjectYaml(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "reference-products", "typescript-api-web", "project-package")
	repoDir := filepath.Clean(filepath.Join(packageDir, ".."))
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(repoDir, 0o755); err != nil {
		t.Fatal(err)
	}
	projectYaml := `schema_version: 1
package:
  name: a2o-reference-typescript-api-web
kanban:
  project: A2OReferenceTypeScript
  selection:
    status: To do
repos:
  app:
    path: ..
    role: product
agent:
  workspace_root: .work/a2o/agent/workspaces
  required_bins:
    - git
    - node
    - npm
    - ruby
runtime:
  live_ref: refs/heads/main
  max_steps: 7
  agent_attempts: 9
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - ruby
          - "{{a2o_root_dir}}/tools/reference_validation/deterministic_worker.rb"
    review:
      skill: skills/review/default.md
      executor:
        command:
          - ruby
          - "{{a2o_root_dir}}/tools/reference_validation/deterministic_worker.rb"
    merge:
      target: merge_to_live
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(projectYaml), 0o644); err != nil {
		t.Fatal(err)
	}
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		SoloBoardPort:  "3480",
		AgentPort:      "7394",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "run-once"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	joined := strings.Join(runner.joinedCalls(), "\n")
	expected := []string{
		"'--kanban-project' 'A2OReferenceTypeScript'",
		"'--agent-source-path' 'app=" + repoDir + "'",
		"'--agent-source-alias' 'app=app'",
		"'--agent-required-bin' 'npm'",
		"'--kanban-repo-label' 'repo:app=app'",
		"'--repo-source' 'app=/workspace/reference-products/typescript-api-web'",
		"'--agent-support-ref' 'refs/heads/main'",
		"'--max-steps' '7'",
	}
	for _, want := range expected {
		if !strings.Contains(joined, want) {
			t.Fatalf("run-once missing %q in:\n%s", want, joined)
		}
	}
	launcherPath := filepath.Join(tempDir, ".work", "a2o", "runtime-host-agent", "launcher.json")
	launcherBody, err := os.ReadFile(launcherPath)
	if err != nil {
		t.Fatalf("launcher config should be written: %v", err)
	}
	if !strings.Contains(string(launcherBody), "deterministic_worker.rb") {
		t.Fatalf("launcher config should contain project executor, got %s", launcherBody)
	}
	if !strings.Contains(joined, "'--agent-env' 'A3_WORKER_LAUNCHER_CONFIG_PATH="+launcherPath+"'") {
		t.Fatalf("run-once should pass launcher config path to agent jobs, calls:\n%s", joined)
	}
	if runner.lastEnv["A3_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS"] != "" {
		t.Fatalf("agent attempts should come from package plan, not env override, got %q", runner.lastEnv["A3_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS"])
	}
	if !strings.Contains(stdout.String(), "runtime_host_agent_loop attempts=9") {
		t.Fatalf("stdout should use package agent_attempts, got %q", stdout.String())
	}
}

func TestRuntimeRunOnceAllowsEnvToOverrideStaleInstanceRuntimeValues(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	t.Setenv("A2O_COMPOSE_PROJECT", "env-project")
	t.Setenv("A2O_COMPOSE_FILE", "env-compose.yml")
	t.Setenv("A2O_BUNDLE_AGENT_PORT", "7555")
	t.Setenv("A2O_BUNDLE_STORAGE_DIR", "/var/lib/a2o/env-runtime")
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "stale-compose.yml",
		ComposeProject: "stale-project",
		RuntimeService: "a2o-runtime",
		AgentPort:      "7394",
		StorageDir:     "/var/lib/a3/stale-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "run-once", "--max-steps", "1", "--agent-attempts", "1"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	joined := strings.Join(runner.joinedCalls(), "\n")
	if !strings.Contains(joined, "docker compose -p env-project -f env-compose.yml up -d a2o-runtime soloboard") {
		t.Fatalf("run-once should use env compose override, calls:\n%s", joined)
	}
	if !strings.Contains(joined, "http://127.0.0.1:7555") {
		t.Fatalf("run-once should use env agent port override, calls:\n%s", joined)
	}
	if !strings.Contains(joined, "/var/lib/a2o/env-runtime") {
		t.Fatalf("run-once should use env storage override, calls:\n%s", joined)
	}
}

func TestRuntimeLoopRunsConfiguredCycles(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		SoloBoardPort:  "3480",
		AgentPort:      "7394",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "loop", "--max-cycles", "2", "--interval", "0s", "--max-steps", "3", "--agent-attempts", "4"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	if count := runner.callCountContains("a3 execute-until-idle"); count != 2 {
		t.Fatalf("execute-until-idle call count=%d, want 2\ncalls:\n%s", count, runner.joinedCalls())
	}
	if !strings.Contains(stdout.String(), "kanban_loop_finished cycles=2") {
		t.Fatalf("stdout should report loop completion, got %q", stdout.String())
	}
	if runner.lastEnv["A3_RUNTIME_RUN_ONCE_MAX_STEPS"] != "3" {
		t.Fatalf("max steps env=%q", runner.lastEnv["A3_RUNTIME_RUN_ONCE_MAX_STEPS"])
	}
	if runner.lastEnv["A3_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS"] != "4" {
		t.Fatalf("agent attempts env=%q", runner.lastEnv["A3_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS"])
	}
}

func TestRuntimeLoopRejectsNegativeMaxCycles(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	err := runRuntimeLoop([]string{"--max-cycles", "-1"}, &fakeRunner{}, &stdout, &stderr)
	if err == nil {
		t.Fatal("runRuntimeLoop should fail with negative max cycles")
	}
	if !strings.Contains(err.Error(), "--max-cycles must be >= 0") {
		t.Fatalf("error should mention invalid max cycles, got %q", err.Error())
	}
}

func TestRuntimeContainerProcessBuildsQuotedBackgroundScript(t *testing.T) {
	script := runtimeContainerProcess{
		WorkingDir: "/workspace",
		Env: map[string]string{
			"A2O_BRANCH_NAMESPACE": "branch with space",
			"A3_ROOT_DIR":          "/workspace",
		},
		EnvShell: map[string]string{
			"A3_SECRET": "${A3_SECRET:-a2o-runtime-secret}",
		},
		Args:        []string{"a3", "execute-until-idle", "--storage-dir", "/var/lib/a3/test runtime"},
		StdoutPath:  "/tmp/a3 runtime.log",
		StderrToOut: true,
		ExitFile:    "/tmp/a3 runtime.exit",
		PIDFile:     "/tmp/a3 runtime.pid",
	}.shellScript()

	for _, want := range []string{
		"cd '/workspace' &&",
		"export A2O_BRANCH_NAMESPACE='branch with space' A3_ROOT_DIR='/workspace' A3_SECRET=${A3_SECRET:-a2o-runtime-secret}",
		"'--storage-dir' '/var/lib/a3/test runtime'",
		"> '/tmp/a3 runtime.log' 2>&1",
		"echo $? > '/tmp/a3 runtime.exit'",
		"& echo $! > '/tmp/a3 runtime.pid'",
	} {
		if !strings.Contains(script, want) {
			t.Fatalf("script missing %q in %q", want, script)
		}
	}
}

func TestArchiveRuntimeStateUsesStructuredDockerCommands(t *testing.T) {
	t.Setenv("A3_RUNTIME_RUN_ONCE_ARCHIVE_STATE", "1")
	config := runtimeInstanceConfig{RuntimeService: "a2o-runtime"}
	plan := runtimeRunOncePlan{
		ComposePrefix: []string{"compose", "-p", "a3-test", "-f", "compose.yml"},
		StorageDir:    "/var/lib/a3/test-runtime",
	}
	runner := &fakeRunner{}
	var stdout bytes.Buffer

	if err := archiveRuntimeStateIfRequested(config, plan, runner, &stdout); err != nil {
		t.Fatalf("archiveRuntimeStateIfRequested returned error: %v", err)
	}

	joined := runner.joinedCalls()
	for _, forbidden := range []string{"bash -lc", "basename \"$storage\""} {
		if strings.Contains(strings.Join(joined, "\n"), forbidden) {
			t.Fatalf("archive should use structured docker commands, found %q in:\n%s", forbidden, strings.Join(joined, "\n"))
		}
	}
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml exec -T a2o-runtime mkdir -p /var/lib/a2o/archive")
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml exec -T a2o-runtime test -e /var/lib/a3/test-runtime")
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml exec -T a2o-runtime mv /var/lib/a3/test-runtime /var/lib/a2o/archive/test-runtime-20260417T000000Z")
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml exec -T a2o-runtime mkdir -p /var/lib/a3/test-runtime")
}

func TestAgentInstallDefaultsOutputFromInstanceConfig(t *testing.T) {
	tempDir := t.TempDir()
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    filepath.Join(tempDir, "package"),
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
	})
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"agent", "install", "--target", "linux-amd64"}, &fakeRunner{}, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	outputPath := filepath.Join(tempDir, hostAgentBinRelativePath)
	if _, err := os.Stat(outputPath); err != nil {
		t.Fatalf("default agent output missing: %v", err)
	}
	if !strings.Contains(stdout.String(), "output="+outputPath) {
		t.Fatalf("stdout should include default output path, got %q", stdout.String())
	}
}

func TestAgentInstallRequiresOutputWithoutInstanceConfig(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{"agent", "install", "--compose-project", "a3-test", "--compose-file", "compose.yml"}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("run should fail without --output and instance config")
	}
	if !strings.Contains(stderr.String(), "--output is required when no runtime instance config is available") {
		t.Fatalf("stderr should mention missing output, got %q", stderr.String())
	}
}

func TestAgentInstallFailsWhenRuntimeContainerIsMissing(t *testing.T) {
	runner := &fakeRunner{emptyContainer: true}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"agent",
		"install",
		"--target",
		"linux-amd64",
		"--output",
		filepath.Join(t.TempDir(), "a3-agent"),
		"--compose-project",
		"a3-test",
		"--compose-file",
		"compose.yml",
	}, runner, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("run should fail when compose ps returns no container")
	}
	if !strings.Contains(stderr.String(), "A2O runtime container not found") {
		t.Fatalf("stderr should mention missing runtime container, got %q", stderr.String())
	}
}

func TestAgentInstallRequiresInstanceConfigOrExplicitCompose(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, t.TempDir(), func() {
		code := run([]string{"agent", "install", "--target", "linux-amd64", "--output", filepath.Join(t.TempDir(), "a3-agent")}, &fakeRunner{}, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail without an instance config")
		}
	})
	if !strings.Contains(stderr.String(), "A2O runtime instance config not found") {
		t.Fatalf("stderr should mention missing instance config, got %q", stderr.String())
	}
}

type fakeRunner struct {
	calls                 [][]string
	emptyContainer        bool
	failShowTask          bool
	taskWithoutCurrentRun bool
	legacyRuntimeOrphans  []string
	failLegacyRuntimeRM   bool
	missingRunHistory     bool
	err                   error
	lastEnv               map[string]string
	nextPID               int
	processCommands       map[int]string
	errorOutput           string
}

func (r *fakeRunner) Run(name string, args ...string) ([]byte, error) {
	call := append([]string{name}, args...)
	r.calls = append(r.calls, call)
	r.lastEnv = map[string]string{
		"A2O_BUNDLE_COMPOSE_FILE":             os.Getenv("A2O_BUNDLE_COMPOSE_FILE"),
		"A2O_BUNDLE_PROJECT":                  os.Getenv("A2O_BUNDLE_PROJECT"),
		"A2O_RUNTIME_RUN_ONCE_MAX_STEPS":      os.Getenv("A2O_RUNTIME_RUN_ONCE_MAX_STEPS"),
		"A2O_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS": os.Getenv("A2O_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS"),
		"A2O_HOST_AGENT_BIN":                  os.Getenv("A2O_HOST_AGENT_BIN"),
		"A2O_RUNTIME_IMAGE":                   os.Getenv("A2O_RUNTIME_IMAGE"),
		"A3_BUNDLE_COMPOSE_FILE":              os.Getenv("A3_BUNDLE_COMPOSE_FILE"),
		"A3_BUNDLE_PROJECT":                   os.Getenv("A3_BUNDLE_PROJECT"),
		"A3_RUNTIME_RUN_ONCE_MAX_STEPS":       os.Getenv("A3_RUNTIME_RUN_ONCE_MAX_STEPS"),
		"A3_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS":  os.Getenv("A3_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS"),
		"A2O_BRANCH_NAMESPACE":                os.Getenv("A2O_BRANCH_NAMESPACE"),
		"A3_HOST_AGENT_BIN":                   os.Getenv("A3_HOST_AGENT_BIN"),
		"A3_RUNTIME_IMAGE":                    os.Getenv("A3_RUNTIME_IMAGE"),
	}
	if r.err != nil {
		output := r.errorOutput
		if output == "" {
			output = "forced error"
		}
		return []byte(output), r.err
	}
	joined := strings.Join(call, " ")
	switch {
	case name == "docker" && len(args) >= 8 && args[0] == "ps" && containsArg(args, "label=com.docker.compose.service=a3-runtime"):
		if len(r.legacyRuntimeOrphans) == 0 {
			return []byte{}, nil
		}
		return []byte(strings.Join(r.legacyRuntimeOrphans, "\n") + "\n"), nil
	case name == "docker" && len(args) >= 3 && args[0] == "rm" && args[1] == "-f":
		if r.failLegacyRuntimeRM {
			return []byte("remove failed\n"), errors.New("remove failed")
		}
		return []byte{}, nil
	case name == "docker" && len(args) >= 3 && args[0] == "volume" && args[1] == "inspect":
		return []byte(`[{"Name":"` + args[2] + `"}]`), nil
	case strings.Contains(joined, " compose ") && strings.Contains(joined, " images --quiet "):
		return []byte("image-123\n"), nil
	case strings.Contains(joined, " compose ") && strings.Contains(joined, " ps --status running -q soloboard"):
		return []byte("soloboard-container\n"), nil
	case strings.Contains(joined, " compose ") && (strings.Contains(joined, " ps --status running -q a2o-runtime") || strings.Contains(joined, " ps --status running -q a2o-runtime")):
		return []byte("runtime-container\n"), nil
	case name == "docker" && len(args) >= 4 && args[0] == "image" && args[1] == "inspect":
		return []byte("ghcr.io/wamukat/a2o-engine@sha256:test\n"), nil
	case strings.Contains(joined, " compose ") && strings.Contains(joined, " ps -q "):
		if r.emptyContainer {
			return []byte("\n"), nil
		}
		return []byte("container-123\n"), nil
	case strings.Contains(joined, " sh -c ") && strings.Contains(joined, "test -f"):
		if r.missingRunHistory {
			return []byte("missing\n"), nil
		}
		return []byte("present\n"), nil
	case strings.Contains(joined, " a3 show-task "):
		if r.failShowTask {
			return []byte("task not found\n"), errors.New("task not found")
		}
		if r.taskWithoutCurrentRun {
			return []byte("task A2O#16 kind=single status=blocked current_run=\nedit_scope=repo_alpha\nverification_scope=repo_alpha\n"), nil
		}
		return []byte("task A2O#16 kind=single status=blocked current_run=run-16\nedit_scope=repo_alpha\nverification_scope=repo_alpha\n"), nil
	case strings.Contains(joined, " ruby -rjson -e ") && strings.Contains(joined, "runtime_latest_run"):
		return []byte("runtime_latest_run run_ref=run-16 task_ref=A2O#16 phase=implementation state=terminal outcome=blocked\n"), nil
	case strings.Contains(joined, " ruby -rjson -e "):
		return []byte("run-16\n"), nil
	case strings.Contains(joined, " a3 show-run "):
		return []byte("run run-16 task=A2O#16 phase=implementation workspace=runtime_workspace source=detached_commit:abc outcome=blocked\nevidence workspace=runtime_workspace source=detached_commit:abc\nlatest_blocked phase=implementation summary=executor failed\nblocked_error_category=executor_failed\n"), nil
	case strings.Contains(joined, " task-get "):
		return []byte(`{"task_ref":"A2O#16","status":"Blocked"}` + "\n"), nil
	case strings.Contains(joined, " task-comment-list "):
		return []byte(`[{"id":61,"comment":"blocked evidence is available","updated":"2026-04-18T07:46:17.996Z"}]` + "\n"), nil
	case strings.Contains(joined, " date -u +%Y%m%dT%H%M%SZ"):
		return []byte("20260417T000000Z\n"), nil
	case strings.Contains(joined, " cat /tmp/a2o-runtime-run-once.exit"):
		return []byte("0\n"), nil
	case name == "docker" && len(args) >= 1 && args[0] == "cp":
		destination := args[len(args)-1]
		if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
			return nil, err
		}
		if err := os.WriteFile(destination, []byte("#!/bin/sh\n"), 0o644); err != nil {
			return nil, err
		}
		return []byte{}, nil
	default:
		return []byte{}, nil
	}
}

func containsArg(args []string, want string) bool {
	for _, arg := range args {
		if arg == want {
			return true
		}
	}
	return false
}

func (r *fakeRunner) StartBackground(name string, args []string, logPath string) (int, error) {
	call := []string{"start-background", name}
	call = append(call, args...)
	call = append(call, logPath)
	r.calls = append(r.calls, call)
	if r.err != nil {
		return 0, r.err
	}
	pid := r.nextPID
	if pid == 0 {
		pid = 12345
	}
	if r.processCommands == nil {
		r.processCommands = map[int]string{}
	}
	command := append([]string{name}, args...)
	r.processCommands[pid] = strings.Join(command, " ")
	r.nextPID = pid + 1
	return pid, nil
}

func (r *fakeRunner) ProcessRunning(pid int) bool {
	r.calls = append(r.calls, []string{"process-running", strconv.Itoa(pid)})
	_, ok := r.processCommands[pid]
	return ok
}

func (r *fakeRunner) ProcessCommand(pid int) string {
	r.calls = append(r.calls, []string{"process-command", strconv.Itoa(pid)})
	return r.processCommands[pid]
}

func (r *fakeRunner) TerminateProcessGroup(pid int) error {
	r.calls = append(r.calls, []string{"terminate-process-group", strconv.Itoa(pid)})
	delete(r.processCommands, pid)
	if r.err != nil {
		return r.err
	}
	return nil
}

func (r fakeRunner) joinedCalls() []string {
	out := make([]string, 0, len(r.calls))
	for _, call := range r.calls {
		out = append(out, strings.Join(call, " "))
	}
	return out
}

func (r fakeRunner) callCount(want string) int {
	count := 0
	for _, call := range r.joinedCalls() {
		if call == want {
			count++
		}
	}
	return count
}

func (r fakeRunner) callCountContains(want string) int {
	count := 0
	for _, call := range r.joinedCalls() {
		if strings.Contains(call, want) {
			count++
		}
	}
	return count
}

func assertCallContains(t *testing.T, calls []string, want string) {
	t.Helper()
	for _, call := range calls {
		if call == want {
			return
		}
	}
	t.Fatalf("missing call %q in:\n%s", want, strings.Join(calls, "\n"))
}

func hasCallPrefix(calls []string, prefix string) bool {
	for _, call := range calls {
		if strings.HasPrefix(call, prefix) {
			return true
		}
	}
	return false
}

func TestRunExternalIncludesOutputOnFailure(t *testing.T) {
	_, err := runExternal(&fakeRunner{err: errors.New("boom")}, "docker", "ps")
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "forced error") {
		t.Fatalf("error should include command output, got %q", err.Error())
	}
}

func TestRunExternalSanitizesInternalRuntimeNames(t *testing.T) {
	runner := &fakeRunner{
		err:         errors.New("boom"),
		errorOutput: "service a3-runtime failed in /var/lib/a3 with 'a3' A3_ROOT_DIR /opt/a3 .a3",
	}
	_, err := runExternal(runner, "docker", "compose", "exec", "-T", "a3-runtime", "sh", "-lc", "A3_ROOT_DIR=/workspace 'a3' execute-until-idle")
	if err == nil {
		t.Fatal("expected error")
	}
	for _, forbidden := range []string{"a3-runtime", "/var/lib/a3", "/opt/a3", ".a3", "A3_ROOT_DIR", "'a3'"} {
		if strings.Contains(err.Error(), forbidden) {
			t.Fatalf("error should hide %q, got %q", forbidden, err.Error())
		}
	}
	if !strings.Contains(err.Error(), "<runtime-service>") {
		t.Fatalf("error should keep actionable runtime service placeholder, got %q", err.Error())
	}
}

func writeTestInstanceConfig(t *testing.T, dir string, config runtimeInstanceConfig) {
	t.Helper()
	path := filepath.Join(dir, ".work", "a2o", "runtime-instance.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatal(err)
	}
}

func writeLegacyTestInstanceConfig(t *testing.T, dir string, config runtimeInstanceConfig) {
	t.Helper()
	path := filepath.Join(dir, ".a3", "runtime-instance.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatal(err)
	}
}

func writeMultiRepoProjectYaml(t *testing.T, packageDir string) {
	t.Helper()
	body := `schema_version: 1
package:
  name: a2o-reference-multi-repo
kanban:
  project: A2OReferenceMultiRepo
  selection:
    status: To do
repos:
  repo_alpha:
    path: ../repos/catalog-service
    role: product
    label: repo:catalog
  repo_beta:
    path: ../repos/storefront
    role: product
    label: repo:storefront
agent:
  workspace_root: .work/a2o/agent/workspaces
  required_bins:
    - git
    - node
    - ruby
runtime:
  live_ref: refs/heads/main
  max_steps: 40
  agent_attempts: 300
  phases:
    implementation:
      skill: skills/implementation/base.md
      executor:
        command:
          - ruby
          - "{{a2o_root_dir}}/tools/reference_validation/deterministic_worker.rb"
    review:
      skill: skills/review/default.md
      executor:
        command:
          - ruby
          - "{{a2o_root_dir}}/tools/reference_validation/deterministic_worker.rb"
    merge:
      target: merge_to_live
      policy: ff_only
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func withChdir(t *testing.T, dir string, fn func()) {
	t.Helper()
	original, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := os.Chdir(original); err != nil {
			t.Fatal(err)
		}
	}()
	fn()
}
