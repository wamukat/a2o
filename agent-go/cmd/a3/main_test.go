package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func setEmptyDockerConfig(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("DOCKER_CONFIG", dir)
	return dir
}

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
		{
			name:     "docker runtime",
			message:  "docker compose failed to start runtime",
			category: "runtime_failed",
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
			if tt.name == "docker runtime" && !strings.Contains(remediation, "Docker runtime status") {
				t.Fatalf("docker remediation=%q", remediation)
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

func TestAgentInstallExportsAgentFromPackageDir(t *testing.T) {
	tempDir := t.TempDir()
	outputPath := filepath.Join(tempDir, "bin", "a3-agent")
	packageDir := writeAgentPackageDir(t, tempDir, map[string]string{"darwin-amd64": "#!/bin/sh\necho package-dir\n"})
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
		"--package-source",
		"package-dir",
		"--package-dir",
		packageDir,
	}, runner, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}
	if got := strings.TrimSpace(string(mustReadTestFile(t, outputPath))); got != "#!/bin/sh\necho package-dir" {
		t.Fatalf("exported agent=%q", got)
	}
	if !strings.Contains(stdout.String(), "source=package-dir") {
		t.Fatalf("stdout should report package-dir source, got %q", stdout.String())
	}
	if len(runner.joinedCalls()) != 0 {
		t.Fatalf("package-dir install should not call docker, calls:\n%s", strings.Join(runner.joinedCalls(), "\n"))
	}
}

func TestAgentInstallAutoFallsBackToRuntimeImageWhenEnvPackageDirIsInvalid(t *testing.T) {
	tempDir := t.TempDir()
	outputPath := filepath.Join(tempDir, "bin", "a3-agent")
	invalidDir := filepath.Join(tempDir, "invalid-packages")
	if err := os.MkdirAll(invalidDir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("A2O_AGENT_PACKAGE_DIR", invalidDir)
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
	}, runner, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}
	assertCallContains(t, runner.joinedCalls(), "docker exec container-123 a3 agent package verify --target darwin-amd64")
	if !strings.Contains(stdout.String(), "source=runtime-image") {
		t.Fatalf("stdout should report runtime-image fallback, got %q", stdout.String())
	}
}

func TestAgentInstallFailsWithoutFallbackWhenExplicitPackageDirIsInvalid(t *testing.T) {
	tempDir := t.TempDir()
	outputPath := filepath.Join(tempDir, "bin", "a3-agent")
	invalidDir := filepath.Join(tempDir, "invalid-packages")
	if err := os.MkdirAll(invalidDir, 0o755); err != nil {
		t.Fatal(err)
	}
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
		"--package-dir",
		invalidDir,
	}, runner, &stdout, &stderr)
	if code == 0 {
		t.Fatal("run should fail for explicit invalid package-dir")
	}
	if !strings.Contains(stderr.String(), "agent package manifest not found") {
		t.Fatalf("stderr should mention invalid package dir, got %q", stderr.String())
	}
	if len(runner.joinedCalls()) != 0 {
		t.Fatalf("explicit invalid package-dir should fail before docker calls, got:\n%s", strings.Join(runner.joinedCalls(), "\n"))
	}
}

func TestProjectBootstrapWritesRuntimeInstanceConfig(t *testing.T) {
	t.Setenv("A2O_RUNTIME_IMAGE", "ghcr.io/wamukat/a2o-engine@sha256:bootstrap")
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
	if config.RuntimeImage != "ghcr.io/wamukat/a2o-engine@sha256:bootstrap" {
		t.Fatalf("RuntimeImage=%q", config.RuntimeImage)
	}
}

func TestProjectBootstrapAcceptsKanbalonePort(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "a2o-project")
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
		"--kanbalone-port",
		"3481",
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
	if config.SoloBoardPort != "3481" {
		t.Fatalf("SoloBoardPort=%q", config.SoloBoardPort)
	}
}

func TestProjectBootstrapRejectsConflictingKanbanPorts(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "a2o-project")
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
		"--kanbalone-port",
		"3481",
		"--soloboard-port",
		"3482",
	}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("run succeeded unexpectedly, stdout=%s", stdout.String())
	}
	if !strings.Contains(stderr.String(), "--kanbalone-port and --soloboard-port specify different values") {
		t.Fatalf("stderr=%q", stderr.String())
	}
}

func TestKanbanPublicURLPrefersKanbalonePortEnv(t *testing.T) {
	t.Setenv("A2O_BUNDLE_KANBALONE_PORT", "3498")
	t.Setenv("A2O_BUNDLE_SOLOBOARD_PORT", "3501")

	got := kanbanPublicURL(runtimeInstanceConfig{SoloBoardPort: "3479"})
	if got != "http://localhost:3498/" {
		t.Fatalf("kanbanPublicURL=%q", got)
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

func TestRuntimeImageReferencePrefersExplicitEnvThenInstanceThenPackagedDefault(t *testing.T) {
	config := runtimeInstanceConfig{RuntimeImage: "ghcr.io/wamukat/a2o-engine@sha256:instance"}
	if got := selectRuntimeImageReference(&config, "ghcr.io/wamukat/a2o-engine@sha256:env", "ghcr.io/wamukat/a2o-engine:packaged"); got != "ghcr.io/wamukat/a2o-engine@sha256:env" {
		t.Fatalf("explicit env should win, got %q", got)
	}
	if got := selectRuntimeImageReference(&config, "", "ghcr.io/wamukat/a2o-engine:packaged"); got != "ghcr.io/wamukat/a2o-engine@sha256:instance" {
		t.Fatalf("instance config should win over packaged default, got %q", got)
	}
	if got := selectRuntimeImageReference(&runtimeInstanceConfig{}, "", "ghcr.io/wamukat/a2o-engine:packaged"); got != "ghcr.io/wamukat/a2o-engine:packaged" {
		t.Fatalf("packaged default should be fallback, got %q", got)
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

func TestProjectTemplateWithSkillsWritesPhaseSkillFiles(t *testing.T) {
	tempDir := t.TempDir()
	outputPath := filepath.Join(tempDir, "project-package", "project.yaml")
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"project",
		"template",
		"--package-name",
		"skill-product",
		"--kanban-project",
		"SkillProduct",
		"--executor-bin",
		"skill-worker",
		"--with-skills",
		"--skill-language",
		"en",
		"--output",
		outputPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}
	for _, rel := range []string{
		"skills/implementation/base.md",
		"skills/review/default.md",
		"skills/review/parent.md",
	} {
		path := filepath.Join(filepath.Dir(outputPath), filepath.FromSlash(rel))
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("skill template %s missing: %v", rel, err)
		}
		required := map[string][]string{
			"skills/implementation/base.md": {"Repository Boundary", "Verification Evidence"},
			"skills/review/default.md":      {"Findings", "Evidence"},
			"skills/review/parent.md":       {"Integration Boundary", "Evidence"},
		}[rel]
		for _, want := range required {
			if !strings.Contains(string(body), want) {
				t.Fatalf("skill template %s missing %q:\n%s", rel, want, string(body))
			}
		}
		if !strings.Contains(stdout.String(), "project_skill_template_written path="+path) {
			t.Fatalf("stdout should mention skill template %s, got %q", path, stdout.String())
		}
	}
	projectYaml, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"skill: \"skills/implementation/base.md\"",
		"skill: \"skills/review/default.md\"",
		"skill: \"skills/review/parent.md\"",
		"parent_review:",
	} {
		if !strings.Contains(string(projectYaml), want) {
			t.Fatalf("project.yaml missing %q:\n%s", want, string(projectYaml))
		}
	}
	if _, err := loadProjectPackageConfig(filepath.Dir(outputPath)); err != nil {
		t.Fatalf("generated project.yaml should load: %v", err)
	}
}

func TestProjectTemplateWithSkillsRequiresOutputPath(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{"project", "template", "--with-skills"}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("run should fail")
	}
	if !strings.Contains(stderr.String(), "--with-skills requires --output") {
		t.Fatalf("stderr should explain output requirement, got %q", stderr.String())
	}
}

func TestProjectTemplateWithSkillsPreflightsBeforeWritingProjectYaml(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "project-package")
	outputPath := filepath.Join(packageDir, "project.yaml")
	existingSkill := filepath.Join(packageDir, "skills", "review", "default.md")
	if err := os.MkdirAll(filepath.Dir(existingSkill), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(existingSkill, []byte("existing\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"project",
		"template",
		"--with-skills",
		"--output",
		outputPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("run should fail when a skill template exists")
	}
	if !strings.Contains(stderr.String(), "skill template already exists") {
		t.Fatalf("stderr should explain existing skill, got %q", stderr.String())
	}
	if _, err := os.Stat(outputPath); !os.IsNotExist(err) {
		t.Fatalf("project.yaml should not be written after skill preflight failure, err=%v", err)
	}
	if _, err := os.Stat(filepath.Join(packageDir, "skills", "implementation", "base.md")); !os.IsNotExist(err) {
		t.Fatalf("implementation skill should not be partially written, err=%v", err)
	}
	body, err := os.ReadFile(existingSkill)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "existing\n" {
		t.Fatalf("existing skill should be untouched, got %q", string(body))
	}
}

func TestProjectTemplateWithSkillsDoesNotLeaveProjectYamlOnSkillWriteFailure(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "project-package")
	outputPath := filepath.Join(packageDir, "project.yaml")
	if err := os.MkdirAll(filepath.Join(packageDir, "skills"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageDir, "skills", "review"), []byte("not a directory\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"project",
		"template",
		"--with-skills",
		"--force",
		"--output",
		outputPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("run should fail when a skill template parent cannot be created")
	}
	if !strings.Contains(stderr.String(), "create template directory") {
		t.Fatalf("stderr should explain template directory failure, got %q", stderr.String())
	}
	if _, err := os.Stat(outputPath); !os.IsNotExist(err) {
		t.Fatalf("project.yaml should not be written after skill write failure, err=%v", err)
	}
	if _, err := os.Stat(filepath.Join(packageDir, "skills", "implementation", "base.md")); !os.IsNotExist(err) {
		t.Fatalf("implementation skill should not be partially written, err=%v", err)
	}
}

func TestWorkerScaffoldWritesRunnablePythonWorkerAndValidateResult(t *testing.T) {
	tempDir := t.TempDir()
	workerPath := filepath.Join(tempDir, "worker.py")
	resultPath := filepath.Join(tempDir, "result.json")
	requestPath := filepath.Join(tempDir, "request.json")
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"worker",
		"scaffold",
		"--language",
		"python",
		"--output",
		workerPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "worker_scaffold_written path="+workerPath+" language=python") {
		t.Fatalf("stdout should describe scaffold path, got %q", stdout.String())
	}
	info, err := os.Stat(workerPath)
	if err != nil {
		t.Fatalf("worker scaffold missing: %v", err)
	}
	if info.Mode().Perm()&0o111 == 0 {
		t.Fatalf("worker scaffold should be executable, mode=%s", info.Mode())
	}

	request := map[string]any{
		"task_ref":   "A2O#62",
		"run_ref":    "run-1",
		"phase":      "implementation",
		"slot_paths": map[string]any{"app": filepath.Join(tempDir, "app")},
	}
	requestBody, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(requestPath, append(requestBody, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
	bundleBody, err := json.Marshal(map[string]any{"request": request})
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("python3", workerPath, "--schema", filepath.Join(tempDir, "schema.json"), "--result", resultPath)
	cmd.Stdin = bytes.NewReader(bundleBody)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("generated worker failed: %v\n%s", err, string(output))
	}

	stdout.Reset()
	stderr.Reset()
	code = run([]string{
		"worker",
		"validate-result",
		"--request",
		requestPath,
		"--result",
		resultPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("validate-result returned %d, stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), "worker_protocol_status=ok") {
		t.Fatalf("validate-result should report ok, got %q", stdout.String())
	}
}

func TestWorkerScaffoldBashIsSelfContained(t *testing.T) {
	tempDir := t.TempDir()
	workerPath := filepath.Join(tempDir, "worker.sh")
	resultPath := filepath.Join(tempDir, "result.json")
	requestPath := filepath.Join(tempDir, "request.json")
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"worker",
		"scaffold",
		"--language",
		"bash",
		"--output",
		workerPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}
	if strings.Contains(readFileString(t, workerPath), "python") {
		t.Fatalf("bash scaffold should not depend on python:\n%s", readFileString(t, workerPath))
	}
	request := map[string]any{
		"task_ref":   "A2O#62",
		"run_ref":    "run-bash",
		"phase":      "implementation",
		"slot_paths": map[string]any{"app": filepath.Join(tempDir, "app")},
	}
	writeJSONFileForTest(t, requestPath, request)
	bundleBody, err := json.Marshal(map[string]any{"request": request})
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("bash", workerPath, "--schema", filepath.Join(tempDir, "schema.json"), "--result", resultPath)
	cmd.Stdin = bytes.NewReader(bundleBody)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("generated bash worker failed: %v\n%s", err, string(output))
	}

	stdout.Reset()
	stderr.Reset()
	code = run([]string{"worker", "validate-result", "--request", requestPath, "--result", resultPath}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("validate-result returned %d, stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
}

func TestWorkerScaffoldGoPrintsGoRunCommandAndValidates(t *testing.T) {
	tempDir := t.TempDir()
	workerPath := filepath.Join(tempDir, "worker.go")
	resultPath := filepath.Join(tempDir, "result.json")
	requestPath := filepath.Join(tempDir, "request.json")
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"worker",
		"scaffold",
		"--language",
		"go",
		"--output",
		workerPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "worker_scaffold_command=go run "+workerPath+" --schema {{schema_path}} --result {{result_path}}") {
		t.Fatalf("go scaffold should print go run command, got %q", stdout.String())
	}
	request := map[string]any{
		"task_ref":   "A2O#62",
		"run_ref":    "run-go",
		"phase":      "implementation",
		"slot_paths": map[string]any{"app": filepath.Join(tempDir, "app")},
	}
	writeJSONFileForTest(t, requestPath, request)
	bundleBody, err := json.Marshal(map[string]any{"request": request})
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("go", "run", workerPath, "--schema", filepath.Join(tempDir, "schema.json"), "--result", resultPath)
	cmd.Stdin = bytes.NewReader(bundleBody)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("generated go worker failed: %v\n%s", err, string(output))
	}

	stdout.Reset()
	stderr.Reset()
	code = run([]string{"worker", "validate-result", "--request", requestPath, "--result", resultPath}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("validate-result returned %d, stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
}

func TestWorkerScaffoldCommandWrapsConfiguredCommandAndValidates(t *testing.T) {
	tempDir := t.TempDir()
	workerPath := filepath.Join(tempDir, "a2o-command-worker")
	fakeWorkerPath := filepath.Join(tempDir, "fake-worker.py")
	resultPath := filepath.Join(tempDir, "result.json")
	requestPath := filepath.Join(tempDir, "request.json")
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"worker",
		"scaffold",
		"--language",
		"command",
		"--output",
		workerPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "worker_scaffold_written path="+workerPath+" language=command") {
		t.Fatalf("stdout should describe command scaffold, got %q", stdout.String())
	}
	if !strings.Contains(readFileString(t, workerPath), "A2O_WORKER_COMMAND") {
		t.Fatalf("command scaffold should document A2O_WORKER_COMMAND:\n%s", readFileString(t, workerPath))
	}

	fakeWorker := `#!/usr/bin/env python3
import json
import sys

bundle = json.load(sys.stdin)
request = bundle["request"]
repo_scope = next(iter(request["slot_paths"]))
json.dump({
    "task_ref": request["task_ref"],
    "run_ref": request["run_ref"],
    "phase": request["phase"],
    "success": True,
    "summary": "worker implemented",
    "failing_command": None,
    "observed_state": None,
    "rework_required": False,
    "changed_files": {},
    "review_disposition": {
        "kind": "completed",
        "repo_scope": repo_scope,
        "summary": "worker self-review clean",
        "description": "The command wrapper preserved the A2O response contract.",
        "finding_key": "completed-no-findings"
    }
}, sys.stdout)
`
	if err := os.WriteFile(fakeWorkerPath, []byte(fakeWorker), 0o755); err != nil {
		t.Fatal(err)
	}
	request := map[string]any{
		"task_ref":   "A2O#62",
		"run_ref":    "run-command",
		"phase":      "implementation",
		"slot_paths": map[string]any{"app": filepath.Join(tempDir, "app")},
	}
	writeJSONFileForTest(t, requestPath, request)
	bundleBody, err := json.Marshal(map[string]any{"request": request})
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(workerPath, "--schema", filepath.Join(tempDir, "schema.json"), "--result", resultPath)
	cmd.Env = append(os.Environ(), "A2O_WORKER_COMMAND="+fakeWorkerPath)
	cmd.Stdin = bytes.NewReader(bundleBody)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("generated command worker failed: %v\n%s", err, string(output))
	}

	stdout.Reset()
	stderr.Reset()
	code = run([]string{"worker", "validate-result", "--request", requestPath, "--result", resultPath}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("validate-result returned %d, stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), "worker_protocol_status=ok") {
		t.Fatalf("validate-result should report ok, got %q", stdout.String())
	}
}

func TestWorkerScaffoldCommandWritesFailureWhenCommandCannotLaunch(t *testing.T) {
	tempDir := t.TempDir()
	workerPath := filepath.Join(tempDir, "a2o-command-worker")
	resultPath := filepath.Join(tempDir, "result.json")
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"worker",
		"scaffold",
		"--language",
		"command",
		"--output",
		workerPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}
	request := map[string]any{
		"task_ref":   "A2O#62",
		"run_ref":    "run-command-missing",
		"phase":      "implementation",
		"slot_paths": map[string]any{"app": filepath.Join(tempDir, "app")},
	}
	bundleBody, err := json.Marshal(map[string]any{"request": request})
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(workerPath, "--schema", filepath.Join(tempDir, "schema.json"), "--result", resultPath)
	cmd.Env = append(os.Environ(), "A2O_WORKER_COMMAND="+filepath.Join(tempDir, "missing-worker"))
	cmd.Stdin = bytes.NewReader(bundleBody)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("generated command worker should write structured failure and exit 0: %v\n%s", err, string(output))
	}
	result := map[string]any{}
	readJSONFileForTest(t, resultPath, &result)
	if result["success"] != false || result["observed_state"] != "worker_command_launch_failed" {
		t.Fatalf("unexpected structured failure: %#v", result)
	}
}

func TestWorkerValidateResultReportsConcreteProtocolErrors(t *testing.T) {
	tempDir := t.TempDir()
	requestPath := filepath.Join(tempDir, "request.json")
	resultPath := filepath.Join(tempDir, "result.json")
	request := []byte(`{"task_ref":"A2O#62","run_ref":"run-1","phase":"implementation"}`)
	result := []byte(`{"task_ref":"A2O#62","run_ref":"run-1","phase":"review","success":"yes","rework_required":false}`)
	if err := os.WriteFile(requestPath, append(request, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(resultPath, append(result, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{
		"worker",
		"validate-result",
		"--request",
		requestPath,
		"--result",
		resultPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("validate-result should fail")
	}
	for _, want := range []string{
		"worker_protocol_check name=result_schema status=blocked",
		"worker_protocol_error=summary must be present",
		"worker_protocol_error=phase must match the worker request",
		"worker_protocol_error=success must be true or false",
		"worker_protocol_status=blocked",
	} {
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("validate-result output missing %q in:\n%s", want, stdout.String())
		}
	}
	if !strings.Contains(stderr.String(), "error_category=configuration_error") {
		t.Fatalf("stderr should classify protocol error, got %q", stderr.String())
	}
}

func TestWorkerValidateResultRequiresReviewDispositionForImplementationSuccess(t *testing.T) {
	tempDir := t.TempDir()
	requestPath := filepath.Join(tempDir, "request.json")
	resultPath := filepath.Join(tempDir, "result.json")
	request := map[string]any{
		"task_ref":   "A2O#62",
		"run_ref":    "run-1",
		"phase":      "implementation",
		"slot_paths": map[string]any{"app": filepath.Join(tempDir, "app")},
	}
	result := map[string]any{
		"task_ref":        "A2O#62",
		"run_ref":         "run-1",
		"phase":           "implementation",
		"success":         true,
		"summary":         "implemented",
		"failing_command": nil,
		"observed_state":  nil,
		"rework_required": false,
		"changed_files":   map[string]any{},
	}
	writeJSONFileForTest(t, requestPath, request)
	writeJSONFileForTest(t, resultPath, result)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"worker", "validate-result", "--request", requestPath, "--result", resultPath}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("validate-result should fail")
	}
	if !strings.Contains(stdout.String(), "worker_protocol_error=review_disposition must be present for implementation success") {
		t.Fatalf("validate-result output missing review_disposition error in:\n%s", stdout.String())
	}
}

func TestWorkerValidateResultRejectsMalformedReviewDispositionOnImplementationFailure(t *testing.T) {
	tempDir := t.TempDir()
	requestPath := filepath.Join(tempDir, "request.json")
	resultPath := filepath.Join(tempDir, "result.json")
	request := map[string]any{
		"task_ref":   "A2O#62",
		"run_ref":    "run-1",
		"phase":      "implementation",
		"slot_paths": map[string]any{"app": filepath.Join(tempDir, "app")},
	}
	result := map[string]any{
		"task_ref":           "A2O#62",
		"run_ref":            "run-1",
		"phase":              "implementation",
		"success":            false,
		"summary":            "implementation failed",
		"failing_command":    "worker",
		"observed_state":     "failed",
		"rework_required":    false,
		"review_disposition": "not-an-object",
	}
	writeJSONFileForTest(t, requestPath, request)
	writeJSONFileForTest(t, resultPath, result)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"worker", "validate-result", "--request", requestPath, "--result", resultPath}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("validate-result should fail")
	}
	if !strings.Contains(stdout.String(), "worker_protocol_error=review_disposition must be an object") {
		t.Fatalf("validate-result output missing review_disposition shape error in:\n%s", stdout.String())
	}
}

func TestWorkerValidateResultRejectsRuntimeProtocolShapeMismatches(t *testing.T) {
	tempDir := t.TempDir()
	requestPath := filepath.Join(tempDir, "request.json")
	resultPath := filepath.Join(tempDir, "result.json")
	request := map[string]any{
		"task_ref":   "A2O#62",
		"run_ref":    "run-1",
		"phase":      "implementation",
		"slot_paths": map[string]any{"app": filepath.Join(tempDir, "app")},
	}
	result := map[string]any{
		"task_ref":        "A2O#62",
		"run_ref":         "run-1",
		"phase":           "implementation",
		"success":         true,
		"summary":         "bad shape",
		"failing_command": 123,
		"observed_state":  true,
		"rework_required": false,
		"diagnostics":     "oops",
		"changed_files":   map[string]any{"app": "README.md"},
		"review_disposition": map[string]any{
			"kind":        "follow_up_child",
			"repo_scope":  "all",
			"summary":     "bad disposition",
			"description": "bad disposition",
			"finding_key": "bad-disposition",
		},
	}
	writeJSONFileForTest(t, requestPath, request)
	writeJSONFileForTest(t, resultPath, result)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"worker", "validate-result", "--request", requestPath, "--result", resultPath}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("validate-result should fail")
	}
	for _, want := range []string{
		"worker_protocol_error=failing_command must be a string or null when success is true",
		"worker_protocol_error=observed_state must be a string or null when success is true",
		"worker_protocol_error=diagnostics must be an object",
		"worker_protocol_error=changed_files for app must be an array of strings",
		"worker_protocol_error=review_disposition.kind must be completed for implementation evidence",
		"worker_protocol_error=review_disposition.repo_scope must be one of app",
	} {
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("validate-result output missing %q in:\n%s", want, stdout.String())
		}
	}
}

func TestWorkerValidateResultRejectsNullableImplementationReviewEvidence(t *testing.T) {
	tempDir := t.TempDir()
	requestPath := filepath.Join(tempDir, "request.json")
	resultPath := filepath.Join(tempDir, "result.json")
	request := map[string]any{
		"task_ref":   "A2O#62",
		"run_ref":    "run-1",
		"phase":      "implementation",
		"slot_paths": map[string]any{"app": filepath.Join(tempDir, "app")},
	}
	result := map[string]any{
		"task_ref":           "A2O#62",
		"run_ref":            "run-1",
		"phase":              "implementation",
		"success":            true,
		"summary":            "no changes",
		"failing_command":    nil,
		"observed_state":     nil,
		"rework_required":    false,
		"changed_files":      nil,
		"review_disposition": nil,
	}
	writeJSONFileForTest(t, requestPath, request)
	writeJSONFileForTest(t, resultPath, result)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"worker", "validate-result", "--request", requestPath, "--result", resultPath}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("validate-result should fail")
	}
	if !strings.Contains(stdout.String(), "worker_protocol_error=review_disposition must be present for implementation success") {
		t.Fatalf("validate-result output missing review_disposition error in:\n%s", stdout.String())
	}
}

func TestWorkerValidateResultMatchesRuntimeEmptyStringSemantics(t *testing.T) {
	tempDir := t.TempDir()
	requestPath := filepath.Join(tempDir, "request.json")
	resultPath := filepath.Join(tempDir, "result.json")
	request := map[string]any{
		"task_ref": "A2O#62",
		"run_ref":  "run-1",
		"phase":    "review",
	}
	result := map[string]any{
		"task_ref":        "",
		"run_ref":         "run-1",
		"phase":           "review",
		"success":         false,
		"summary":         "review finding",
		"failing_command": "",
		"observed_state":  "",
		"rework_required": false,
	}
	writeJSONFileForTest(t, requestPath, request)
	writeJSONFileForTest(t, resultPath, result)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"worker", "validate-result", "--request", requestPath, "--result", resultPath}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("validate-result should fail because task_ref does not match")
	}
	if !strings.Contains(stdout.String(), "worker_protocol_error=task_ref must match the worker request") {
		t.Fatalf("validate-result should report task_ref mismatch, got:\n%s", stdout.String())
	}
	if strings.Contains(stdout.String(), "failing_command must be a string") || strings.Contains(stdout.String(), "observed_state must be a string") {
		t.Fatalf("empty failing_command/observed_state strings should match runtime semantics, got:\n%s", stdout.String())
	}
}

func TestWorkerValidateResultHonorsConfiguredReviewScopesAndAliases(t *testing.T) {
	tempDir := t.TempDir()
	requestPath := filepath.Join(tempDir, "request.json")
	resultPath := filepath.Join(tempDir, "result.json")
	request := map[string]any{
		"task_ref": "A2O#62",
		"run_ref":  "run-1",
		"phase":    "implementation",
	}
	result := map[string]any{
		"task_ref":        "A2O#62",
		"run_ref":         "run-1",
		"phase":           "implementation",
		"success":         true,
		"summary":         "configured scope",
		"failing_command": nil,
		"observed_state":  nil,
		"rework_required": false,
		"changed_files":   map[string]any{},
		"review_disposition": map[string]any{
			"kind":        "completed",
			"repo_scope":  "pkg",
			"summary":     "configured scope",
			"description": "configured scope",
			"finding_key": "",
		},
	}
	writeJSONFileForTest(t, requestPath, request)
	writeJSONFileForTest(t, resultPath, result)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{
		"worker",
		"validate-result",
		"--request",
		requestPath,
		"--result",
		resultPath,
		"--review-scope",
		"package",
		"--repo-scope-alias",
		"pkg=package",
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("validate-result returned %d, stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), "worker_protocol_status=ok") {
		t.Fatalf("validate-result should report ok, got %q", stdout.String())
	}
}

func readFileString(t *testing.T, path string) string {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}

func writeJSONFileForTest(t *testing.T, path string, payload any) {
	t.Helper()
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(body, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
}

func readJSONFileForTest(t *testing.T, path string, target any) {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(body, target); err != nil {
		t.Fatal(err)
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
		"a2o upgrade check",
		"a2o project bootstrap [--package DIR]",
		"a2o project lint [--package DIR]",
		"a2o kanban up [--build]",
		"a2o kanban doctor",
		"a2o kanban url",
		"a2o runtime up [--build] [--pull]",
		"a2o runtime down",
		"a2o runtime resume [--interval DURATION] [--agent-poll-interval DURATION] # resume scheduler",
		"a2o runtime pause                        # pause scheduler after current work",
		"a2o runtime status",
		"a2o runtime image-digest",
		"a2o runtime doctor",
		"a2o runtime describe-task TASK_REF",
		"a2o runtime reset-task TASK_REF",
		"a2o runtime watch-summary",
		"a2o runtime skill-feedback list",
		"a2o runtime skill-feedback propose",
		"a2o runtime logs TASK_REF [--follow]",
		"a2o runtime show-artifact ARTIFACT_ID",
		"a2o runtime clear-logs (--task-ref TASK_REF | --run-ref RUN_REF | --all-analysis) [--phase PHASE] [--role ROLE] [--apply]",
		"a2o runtime run-once [--max-steps N] [--agent-attempts N] [--agent-poll-interval DURATION]",
		"a2o runtime loop [--interval DURATION] [--max-cycles N] [--agent-poll-interval DURATION]",
		"a2o agent install [--target auto] [--output PATH] [--package-source auto|package-dir|runtime-image] [--package-dir DIR] [--build]",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("usage missing %q in %q", want, output)
		}
	}
	for _, hidden := range []string{
		"a2o runtime start",
		"a2o runtime stop",
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
	for _, group := range []string{"project", "kanban", "runtime", "agent", "upgrade"} {
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
		{name: "project lint", args: []string{"project", "lint", "-bad"}, want: "Usage of a2o project lint:"},
		{name: "upgrade check", args: []string{"upgrade", "check", "-bad"}, want: "Usage of a2o upgrade check:"},
		{name: "kanban up", args: []string{"kanban", "up", "-bad"}, want: "Usage of a2o kanban up:"},
		{name: "kanban doctor", args: []string{"kanban", "doctor", "-bad"}, want: "Usage of a2o kanban doctor:"},
		{name: "kanban url", args: []string{"kanban", "url", "-bad"}, want: "Usage of a2o kanban url:"},
		{name: "runtime up", args: []string{"runtime", "up", "-bad"}, want: "Usage of a2o runtime up:"},
		{name: "runtime down", args: []string{"runtime", "down", "-bad"}, want: "Usage of a2o runtime down:"},
		{name: "runtime resume", args: []string{"runtime", "resume", "-bad"}, want: "Usage of a2o runtime resume:"},
		{name: "runtime pause", args: []string{"runtime", "pause", "-bad"}, want: "Usage of a2o runtime pause:"},
		{name: "runtime start compatibility alias", args: []string{"runtime", "start", "-bad"}, want: "Usage of a2o runtime resume:"},
		{name: "runtime stop compatibility alias", args: []string{"runtime", "stop", "-bad"}, want: "Usage of a2o runtime pause:"},
		{name: "runtime status", args: []string{"runtime", "status", "-bad"}, want: "Usage of a2o runtime status:"},
		{name: "runtime image-digest", args: []string{"runtime", "image-digest", "-bad"}, want: "Usage of a2o runtime image-digest:"},
		{name: "runtime doctor", args: []string{"runtime", "doctor", "-bad"}, want: "Usage of a2o runtime doctor:"},
		{name: "runtime run-once", args: []string{"runtime", "run-once", "-bad"}, want: "Usage of a2o runtime run-once:"},
		{name: "runtime watch-summary", args: []string{"runtime", "watch-summary", "-bad"}, want: "Usage of a2o runtime watch-summary:"},
		{name: "runtime skill-feedback list", args: []string{"runtime", "skill-feedback", "list", "-bad"}, want: "Usage of a2o runtime skill-feedback list:"},
		{name: "runtime skill-feedback propose", args: []string{"runtime", "skill-feedback", "propose", "-bad"}, want: "Usage of a2o runtime skill-feedback propose:"},
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
		"      policy: ff_only",
		"      target_ref: refs/heads/main",
		"",
	}, "\n")
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(projectYaml), 0o644); err != nil {
		t.Fatal(err)
	}
	readme := "Historical note: A3_WORKER_REQUEST_PATH and .a2o/workspace.json are not public.\n"
	if err := os.WriteFile(filepath.Join(packageDir, "README.md"), []byte(readme), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageDir, "CHANGELOG"), []byte(readme), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(packageDir, "fixtures"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageDir, "fixtures", "sample.json"), []byte(`{"note":"A3_SECRET"}`), 0o644); err != nil {
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
	setEmptyDockerConfig(t)
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
		"doctor_check name=docker_credential_helpers status=ok detail=config_not_found",
		"doctor_check name=executor_config status=ok detail=commands=sh",
		"doctor_check name=project_script_contract status=ok detail=public A2O script contract only",
		"doctor_check name=fixture_reference status=ok detail=no production config fixture references",
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

func TestDoctorDetectsMissingDockerCredentialHelper(t *testing.T) {
	dockerConfigDir := t.TempDir()
	t.Setenv("DOCKER_CONFIG", dockerConfigDir)
	if err := os.WriteFile(filepath.Join(dockerConfigDir, "config.json"), []byte(`{"credsStore":"a2o-missing-test-helper"}`), 0o644); err != nil {
		t.Fatal(err)
	}

	type reportLine struct {
		name   string
		ok     bool
		detail string
		action string
	}
	reports := []reportLine{}
	checkDockerCredentialHelpers(func(name string, ok bool, detail string, action string) {
		reports = append(reports, reportLine{name: name, ok: ok, detail: detail, action: action})
	})

	if len(reports) != 1 {
		t.Fatalf("expected one report, got %#v", reports)
	}
	got := reports[0]
	if got.name != "docker_credential_helpers" || got.ok {
		t.Fatalf("expected blocked docker credential helper report, got %#v", got)
	}
	for _, want := range []string{
		"missing=credsStore=a2o-missing-test-helper binary=docker-credential-a2o-missing-test-helper",
		"config.json",
	} {
		if !strings.Contains(got.detail, want) {
			t.Fatalf("detail missing %q in %q", want, got.detail)
		}
	}
	if !strings.Contains(got.action, "temporary DOCKER_CONFIG") || !strings.Contains(got.action, `{"auths":{}}`) {
		t.Fatalf("action should explain temporary DOCKER_CONFIG workaround, got %q", got.action)
	}
}

func TestDoctorFlagsFixtureReferencesInProductionProjectYaml(t *testing.T) {
	tempDir := t.TempDir()
	setEmptyDockerConfig(t)
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
		"        command: [\"tests/fixtures/dummy-worker.sh\", \"--result\", \"{{result_path}}\"]",
		"    review:",
		"      skill: skills/review/default.md",
		"    merge:",
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
		if code == 0 {
			t.Fatalf("doctor should fail for production fixture references, stdout=%s", stdout.String())
		}
	})

	for _, want := range []string{
		"doctor_check name=fixture_reference status=blocked",
		"project.yaml:tests/fixtures",
		"project.yaml:dummy-worker",
		"doctor_status=blocked",
	} {
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("doctor output missing %q in:\n%s", want, stdout.String())
		}
	}
}

func TestDoctorFlagsPrivateProjectScriptContractUsage(t *testing.T) {
	tempDir := t.TempDir()
	setEmptyDockerConfig(t)
	packageDir := filepath.Join(tempDir, "package")
	repoDir := filepath.Join(tempDir, "repo")
	if err := os.MkdirAll(filepath.Join(packageDir, "commands"), 0o755); err != nil {
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
		"      policy: ff_only",
		"      target_ref: refs/heads/main",
		"",
	}, "\n")
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(projectYaml), 0o644); err != nil {
		t.Fatal(err)
	}
	readme := "Historical note: A3_WORKER_REQUEST_PATH and .a2o/workspace.json are not public.\n"
	if err := os.WriteFile(filepath.Join(packageDir, "README.md"), []byte(readme), 0o644); err != nil {
		t.Fatal(err)
	}
	taskfile := "version: '3'\ntasks:\n  verify:\n    cmds: ['echo $A3_RUNTIME_IMAGE']\n"
	if err := os.WriteFile(filepath.Join(packageDir, "Taskfile.yml"), []byte(taskfile), 0o644); err != nil {
		t.Fatal(err)
	}
	dockerfile := "RUN echo $A3_SECRET\n"
	if err := os.WriteFile(filepath.Join(packageDir, "Dockerfile"), []byte(dockerfile), 0o644); err != nil {
		t.Fatal(err)
	}
	justfile := "verify:\n    echo $A3_BUNDLE_PROJECT\n"
	if err := os.WriteFile(filepath.Join(packageDir, "Justfile"), []byte(justfile), 0o644); err != nil {
		t.Fatal(err)
	}
	procfile := "worker: echo $A3_BUNDLE_PROJECT\n"
	if err := os.WriteFile(filepath.Join(packageDir, "Procfile"), []byte(procfile), 0o644); err != nil {
		t.Fatal(err)
	}
	envExample := "A3_RUNTIME_IMAGE=example\n"
	if err := os.WriteFile(filepath.Join(packageDir, ".env.example"), []byte(envExample), 0o644); err != nil {
		t.Fatal(err)
	}
	privateScript := "echo $A3_WORKER_REQUEST_PATH && ruby -e 'puts File.join(\".a2o\", \"workspace.json\")'\n"
	if err := os.WriteFile(filepath.Join(packageDir, "commands", "worker.sh"), []byte(privateScript), 0o644); err != nil {
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
		if code == 0 {
			t.Fatalf("doctor should fail for private script contract usage, stdout=%s", stdout.String())
		}
	})

	for _, want := range []string{
		"doctor_check name=project_script_contract status=blocked",
		"Dockerfile:A3_*",
		"Justfile:A3_*",
		"Procfile:A3_*",
		"Taskfile.yml:A3_*",
		".env.example:A3_*",
		"commands/worker.sh:.a2o/workspace.json",
		"commands/worker.sh:A3_*",
		"action=replace A3_* names with A2O_* public env such as A2O_WORKER_REQUEST_PATH",
		"replace private .a2o/.a3 metadata reads with the JSON at A2O_WORKER_REQUEST_PATH; use slot_paths for repo paths",
	} {
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("doctor output missing %q in:\n%s", want, stdout.String())
		}
	}
}

func TestDoctorFlagsPrivateContractUsageInProjectYaml(t *testing.T) {
	tempDir := t.TempDir()
	setEmptyDockerConfig(t)
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
		"        command: [\"sh\", \"-c\", \"echo $A3_WORKER_RESULT_PATH && cat .a3/slot.json\"]",
		"    review:",
		"      skill: skills/review/default.md",
		"    merge:",
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
		if code == 0 {
			t.Fatalf("doctor should fail for private project.yaml contract usage, stdout=%s", stdout.String())
		}
	})

	for _, want := range []string{
		"doctor_check name=project_script_contract status=blocked",
		"project.yaml:.a3/slot.json",
		"project.yaml:A3_*",
	} {
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("doctor output missing %q in:\n%s", want, stdout.String())
		}
	}
}

func TestProjectLintFlagsFixtureAndLegacyLeaks(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(filepath.Join(packageDir, "commands"), 0o755); err != nil {
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
		"    path: ..",
		"agent:",
		"  required_bins: [\"sh\"]",
		"runtime:",
		"  phases:",
		"    implementation:",
		"      skill: skills/implementation/base.md",
		"      executor:",
		"        command: [\"tests/fixtures/dummy-worker.sh\", \"--schema\", \"{{schema_path}}\", \"--result\", \"{{result_path}}\"]",
		"    review:",
		"      skill: skills/review/default.md",
		"    merge:",
		"      policy: ff_only",
		"      target_ref: refs/heads/main",
		"",
	}, "\n")
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(projectYaml), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageDir, "README.md"), []byte("Do not document $A3_WORKER_REQUEST_PATH, .a2o/workspace.json, launcher.json, or tests/fixtures workers here.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageDir, "commands", "dummy-worker.sh"), []byte("echo $A3_WORKER_REQUEST_PATH\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "lint", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project lint should fail for fixture and legacy leaks, stdout=%s", stdout.String())
	}
	for _, want := range []string{
		"lint_check name=project_package status=ok",
		"lint_check name=project_script_contract status=blocked",
		"commands/dummy-worker.sh:A3_*",
		"action=replace A3_* names with A2O_* public env such as A2O_WORKER_REQUEST_PATH",
		"lint_check name=user_facing_contract status=blocked",
		"README.md:.a2o/workspace.json",
		"README.md:A3_*",
		"README.md:launcher.json",
		"README.md:tests/fixtures",
		"document A2O_WORKER_REQUEST_PATH fields such as slot_paths, scope_snapshot, and phase_runtime instead of private .a2o/.a3 metadata",
		"document project.yaml runtime.phases.*.executor.command instead of generated launcher.json",
		"lint_check name=fixture_reference status=blocked",
		"project.yaml:tests/fixtures",
		"commands/dummy-worker.sh:fixture-like command name",
		"lint_status=blocked",
	} {
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("project lint output missing %q in:\n%s", want, stdout.String())
		}
	}
}

func TestProjectLintAllowsFixtureReferencesOnlyForExplicitAlternateConfig(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(filepath.Join(packageDir, "tests", "fixtures"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	testConfig := strings.ReplaceAll(readFileString(t, filepath.Join(packageDir, "project.yaml")), "{{a2o_root_dir}}/tools/reference_validation/deterministic_worker.rb", "tests/fixtures/deterministic-worker.rb")
	if err := os.WriteFile(filepath.Join(packageDir, "project-test.yaml"), []byte(testConfig), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageDir, "tests", "fixtures", "deterministic-worker.rb"), []byte("puts 'ok'\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "lint", "--package", packageDir, "--config", "project-test.yaml"}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("alternate config lint should pass, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
	if strings.Contains(stdout.String(), "project-test.yaml:tests/fixtures") {
		t.Fatalf("explicit alternate config should allow fixture references, got:\n%s", stdout.String())
	}

	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(testConfig), 0o644); err != nil {
		t.Fatal(err)
	}
	stdout.Reset()
	stderr.Reset()
	code = run([]string{"project", "lint", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("normal project.yaml lint should fail when it references fixtures")
	}
	if !strings.Contains(stdout.String(), "project.yaml:tests/fixtures") {
		t.Fatalf("normal project.yaml should report fixture reference, got:\n%s", stdout.String())
	}
}

func TestProjectLintTreatsExplicitConfigOutsidePackageAsAlternateEvenWhenNamedProjectYaml(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	alternateDir := filepath.Join(tempDir, "test-profile")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(alternateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	testConfig := strings.ReplaceAll(readFileString(t, filepath.Join(packageDir, "project.yaml")), "{{a2o_root_dir}}/tools/reference_validation/deterministic_worker.rb", "tests/fixtures/deterministic-worker.rb")
	alternateConfigPath := filepath.Join(alternateDir, "project.yaml")
	if err := os.WriteFile(alternateConfigPath, []byte(testConfig), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir, "--config", alternateConfigPath}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("explicit alternate config named project.yaml should pass, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
	if strings.Contains(stdout.String(), "tests/fixtures") {
		t.Fatalf("explicit alternate config should not report fixture reference, got:\n%s", stdout.String())
	}
}

func TestProjectLintReportsUnusedCommandsAsWarning(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(filepath.Join(packageDir, "commands"), 0o755); err != nil {
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
		"    path: ..",
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
		"    verification:",
		"      commands:",
		"        - app/project-package/commands/verify.sh",
		"    merge:",
		"      policy: ff_only",
		"      target_ref: refs/heads/main",
		"",
	}, "\n")
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(projectYaml), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageDir, "commands", "verify.sh"), []byte("echo ok\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageDir, "commands", "unused.sh"), []byte("echo unused\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "lint", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("project lint warnings should not fail, code=%d stderr=%s stdout=%s", code, stderr.String(), stdout.String())
	}
	for _, want := range []string{
		"lint_check name=project_package status=ok",
		"lint_check name=project_script_contract status=ok",
		"lint_check name=user_facing_contract status=ok",
		"lint_check name=fixture_reference status=ok",
		"lint_check name=unused_commands status=warning detail=commands/unused.sh",
		"lint_status=warning",
	} {
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("project lint output missing %q in:\n%s", want, stdout.String())
		}
	}
}

func TestProjectLintRejectsLegacyManifest(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packageDir, "manifest.yml"), []byte("schema_version: 1\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "lint", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project lint should fail for legacy manifest, stdout=%s", stdout.String())
	}
	for _, want := range []string{
		"lint_check name=project_package status=blocked",
		"manifest.yml is no longer supported",
		"lint_status=blocked",
	} {
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("project lint output missing %q in:\n%s", want, stdout.String())
		}
	}
}

func TestProjectLintRejectsUnsupportedAgentWorkspaceCleanupPolicy(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
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
		"    path: ..",
		"agent:",
		"  workspace_cleanup_policy: keep",
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
		"      policy: ff_only",
		"      target_ref: refs/heads/main",
		"",
	}, "\n")
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(projectYaml), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "lint", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project lint should fail for unsupported workspace cleanup policy, stdout=%s", stdout.String())
	}
	for _, want := range []string{
		"lint_check name=project_package status=blocked",
		"invalid agent.workspace_cleanup_policy",
		"workspace cleanup policy is managed by A2O runtime and is not supported in project.yaml",
		"lint_status=blocked",
	} {
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("project lint output missing %q in:\n%s", want, stdout.String())
		}
	}
}

func TestDoctorAgentInstallFailureShowsExactOutputPath(t *testing.T) {
	tempDir := t.TempDir()
	setEmptyDockerConfig(t)
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

func TestRuntimeRunOnceUsesExplicitProjectConfig(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	testConfig := strings.ReplaceAll(readFileString(t, filepath.Join(packageDir, "project.yaml")), "A2OReferenceMultiRepo", "A2OReferenceMultiRepoTest")
	testConfig = strings.ReplaceAll(testConfig, "{{a2o_root_dir}}/tools/reference_validation/deterministic_worker.rb", "tests/fixtures/deterministic-worker.rb")
	if err := os.WriteFile(filepath.Join(packageDir, "project-test.yaml"), []byte(testConfig), 0o644); err != nil {
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
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "run-once", "--project-config", "project-test.yaml", "--max-steps", "1", "--agent-attempts", "2"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	joined := strings.Join(runner.joinedCalls(), "\n")
	if !strings.Contains(joined, "'"+filepath.Join(packageDir, "project-test.yaml")+"'") {
		t.Fatalf("run-once should pass explicit project config to runtime, calls:\n%s", joined)
	}
	if !strings.Contains(joined, "'--kanban-project' 'A2OReferenceMultiRepoTest'") {
		t.Fatalf("run-once should load kanban project from explicit config, calls:\n%s", joined)
	}
	launcherConfig := filepath.Join(tempDir, runtimeHostAgentRelativePath, "launcher.json")
	if !strings.Contains(readFileString(t, launcherConfig), "tests/fixtures/deterministic-worker.rb") {
		t.Fatalf("launcher config should come from explicit project config:\n%s", readFileString(t, launcherConfig))
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

func TestRuntimeRunOnceRejectsLegacyRuntimeLiveRef(t *testing.T) {
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
  live_ref: refs/heads/main
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
			t.Fatalf("run should fail with legacy runtime.live_ref")
		}
	})

	if !strings.Contains(stderr.String(), "invalid runtime.live_ref") || !strings.Contains(stderr.String(), "runtime.live_ref is no longer supported") {
		t.Fatalf("stderr should reject legacy runtime.live_ref, got %q", stderr.String())
	}
	if len(runner.calls) != 0 {
		t.Fatalf("runtime should fail before docker calls, got:\n%s", runner.joinedCalls())
	}
}

func TestRuntimeRunOnceRejectsPublicMergeTarget(t *testing.T) {
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
			t.Fatalf("run should fail with public merge target")
		}
	})

	if !strings.Contains(stderr.String(), "invalid runtime.phases.merge") || !strings.Contains(stderr.String(), "target is no longer supported") {
		t.Fatalf("stderr should reject public merge target, got %q", stderr.String())
	}
	if len(runner.calls) != 0 {
		t.Fatalf("runtime should fail before docker calls, got:\n%s", runner.joinedCalls())
	}
}

func TestProjectValidateRejectsMissingMergePolicy(t *testing.T) {
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
          - worker
    merge:
      target_ref: refs/heads/main
`
	if err := os.WriteFile(filepath.Join(packageDir, "project.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"project", "validate", "--package", packageDir}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("project validate should fail for missing merge policy, stdout=%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "lint_check name=project_package status=blocked") ||
		!strings.Contains(stdout.String(), "invalid runtime.phases.merge") ||
		!strings.Contains(stdout.String(), "policy must be provided") {
		t.Fatalf("project validate should reject missing merge policy, stdout=%s stderr=%s", stdout.String(), stderr.String())
	}
}

func TestRuntimeRunOnceRejectsLegacyWorkspaceHook(t *testing.T) {
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
      workspace_hook: hooks/prepare-runtime.sh
      executor:
        command:
          - worker
    review:
      skill: skills/review/default.md
      executor:
        command:
          - worker
    merge:
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
			t.Fatalf("run should fail with legacy workspace_hook")
		}
	})

	if !strings.Contains(stderr.String(), "invalid runtime.phases") || !strings.Contains(stderr.String(), "implementation.workspace_hook is no longer supported") {
		t.Fatalf("stderr should reject legacy workspace_hook, got %q", stderr.String())
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
	t.Setenv("A2O_WORKER_LAUNCHER_CONFIG_PATH", filepath.Join(tempDir, "legacy-launcher.json"))

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

func TestRuntimeResumeLaunchesForegroundLoopInBackground(t *testing.T) {
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
		code := run([]string{"runtime", "resume", "--interval", "5s", "--max-steps", "2", "--agent-attempts", "3", "--agent-poll-interval", "7s"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	joined := strings.Join(runner.joinedCalls(), "\n")
	for _, want := range []string{
		"start-background",
		"runtime loop --interval 5s --max-steps 2 --agent-attempts 3 --agent-poll-interval 7s",
		filepath.Join(tempDir, ".work", "a2o-runtime", "scheduler.log"),
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("runtime resume missing %q in:\n%s", want, joined)
		}
	}
	if !strings.Contains(stdout.String(), "runtime_scheduler_resumed") {
		t.Fatalf("stdout should report scheduler resume, got %q", stdout.String())
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
		t.Fatalf("runtime resume should guide operator to describe-task, got %q", stdout.String())
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
		"execution_started_at=2026-04-11T08:00:00Z",
		"execution_finished_at=2026-04-11T08:00:42Z",
		"execution_duration_seconds=42.000",
		"agent_artifact role=combined-log id=worker-run-16-implementation-combined-log retention=analysis media_type=text/plain byte_size=42",
		"agent_artifact_read=a2o runtime show-artifact worker-run-16-implementation-combined-log",
		"--- kanban_task ---",
		"\"task_ref\":\"A2O#16\"",
		"comment_count=1",
		"comment[0] id=61 updated=2026-04-18T07:46:17.996Z body=blocked evidence is available",
		"operator_logs runtime_log=/tmp/a2o-runtime-run-once.log server_log=/tmp/a2o-runtime-run-once-agent-server.log host_agent_log=",
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
		"docker compose -p a3-test -f compose.yml exec -T a2o-runtime bash -lc",
		"export A3_SECRET_REFERENCE=\"${A3_SECRET_REFERENCE:-A3_SECRET}\"",
		"export A2O_INTERNAL_SECRET_REFERENCE=\"${A2O_INTERNAL_SECRET_REFERENCE:-a2o-runtime-secret}\"",
		"show-run",
		filepath.Join(packageDir, "project.yaml"),
		"docker compose -p a3-test -f compose.yml exec -T a2o-runtime python3 /opt/a2o/share/tools/kanban/cli.py --backend soloboard --base-url http://soloboard:3000 task-comment-list --project A2OReferenceMultiRepo --task A2O#16",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("describe-task missing call %q in:\n%s", want, joined)
		}
	}
}

func TestRuntimeResetTaskPrintsBlockedRecoveryPlan(t *testing.T) {
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
		StorageDir:     "/var/lib/a2o/test-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "reset-task", "A2O#16"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	output := stdout.String()
	for _, want := range []string{
		"reset_task_plan task_ref=A2O#16 mode=dry-run",
		"kanban_project=A2OReferenceMultiRepo kanban_url=http://localhost:3480",
		"runtime_storage=internal-managed project_config=" + filepath.Join(packageDir, "project.yaml") + " surface_source=project-package",
		"affected_artifact kind=kanban task_ref=A2O#16",
		"affected_artifact kind=runtime_state file=tasks.json action=preserve",
		"affected_artifact kind=runtime_state file=runs.json action=preserve",
		"affected_artifact kind=evidence directory=evidence action=preserve",
		"affected_artifact kind=blocked_diagnosis directory=blocked_diagnoses action=preserve",
		"affected_artifact kind=workspace path=" + filepath.Join(tempDir, ".work", "a2o", "agent", "workspaces"),
		"affected_artifact kind=branch namespace=test",
		"recovery_step 1 command=a2o runtime describe-task A2O#16",
		"recovery_step 6 command=a2o runtime run-once",
		"apply_supported=false",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("reset-task missing %q in:\n%s", want, output)
		}
	}
	if len(runner.calls) != 0 {
		t.Fatalf("reset-task dry-run should not call external commands, got %v", runner.calls)
	}
}

func TestRuntimeShowArtifactReadsContainerArtifact(t *testing.T) {
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
		code := run([]string{"runtime", "show-artifact", "worker-run-16-implementation-combined-log"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	if !strings.Contains(stdout.String(), "agent raw log line") {
		t.Fatalf("show-artifact should print artifact content, got:\n%s", stdout.String())
	}
	joined := strings.Join(runner.joinedCalls(), "\n")
	want := "docker compose -p a3-test -f compose.yml exec -T a2o-runtime a3 agent-artifact-read --storage-dir /var/lib/a3/test-runtime worker-run-16-implementation-combined-log"
	if !strings.Contains(joined, want) {
		t.Fatalf("show-artifact missing call %q in:\n%s", want, joined)
	}
}

func TestRuntimeClearLogsRunsContainerClearInDryRunModeByDefault(t *testing.T) {
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
		code := run([]string{"runtime", "clear-logs", "--task-ref", "A2O#16"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	if !strings.Contains(stdout.String(), "runtime_log_clear=dry_run") {
		t.Fatalf("clear-logs should print dry-run summary, got:\n%s", stdout.String())
	}
	joined := strings.Join(runner.joinedCalls(), "\n")
	want := "docker compose -p a3-test -f compose.yml exec -T a2o-runtime a3 clear-runtime-logs --storage-backend json --storage-dir /var/lib/a3/test-runtime --task-ref A2O#16"
	if !strings.Contains(joined, want) {
		t.Fatalf("clear-logs missing call %q in:\n%s", want, joined)
	}
	if strings.Contains(joined, "--apply") {
		t.Fatalf("clear-logs should not apply by default:\n%s", joined)
	}
}

func TestRuntimeLogsPrintsCompletedPhaseArtifacts(t *testing.T) {
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
	runner := &fakeRunner{
		logManifestOutput: `{"run_ref":"run-16","current_run":"run-16","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":false,"artifacts":[{"phase":"implementation","artifact_id":"worker-run-16-implementation-ai-raw-log","mode":"ai-raw-log"},{"phase":"implementation","artifact_id":"worker-run-16-implementation-combined-log","mode":"combined-log"}]}`,
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "logs", "A2O#16"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	output := stdout.String()
	if !strings.Contains(output, "=== phase: implementation (ai-raw-log) artifact=worker-run-16-implementation-ai-raw-log ===") {
		t.Fatalf("runtime logs missing ai-raw-log header, got:\n%s", output)
	}
	if !strings.Contains(output, "=== phase: implementation (combined-log) artifact=worker-run-16-implementation-combined-log ===") {
		t.Fatalf("runtime logs missing combined-log header, got:\n%s", output)
	}
	if !strings.Contains(output, "agent raw log line") {
		t.Fatalf("runtime logs missing artifact content, got:\n%s", output)
	}
	joined := strings.Join(runner.joinedCalls(), "\n")
	for _, want := range []string{
		"docker compose -p a3-test -f compose.yml exec -T a2o-runtime a3 show-task --storage-backend json --storage-dir /var/lib/a3/test-runtime A2O#16",
		"docker compose -p a3-test -f compose.yml exec -T a2o-runtime ruby -rjson -e",
		"docker compose -p a3-test -f compose.yml exec -T a2o-runtime a3 agent-artifact-read --storage-dir /var/lib/a3/test-runtime worker-run-16-implementation-ai-raw-log",
		"docker compose -p a3-test -f compose.yml exec -T a2o-runtime a3 agent-artifact-read --storage-dir /var/lib/a3/test-runtime worker-run-16-implementation-combined-log",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("runtime logs missing call %q in:\n%s", want, joined)
		}
	}
}

func TestRuntimeLogsFollowsLatestActiveRunWhenTaskCurrentRunIsBlank(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	liveLogRoot := filepath.Join(tempDir, "host-root", "ai-raw-logs")
	liveLogPath := filepath.Join(liveLogRoot, "A2O-16", "implementation.log")
	if err := os.MkdirAll(filepath.Dir(liveLogPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(liveLogPath, []byte("live log line\n"), 0o644); err != nil {
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
	runner := &fakeRunner{
		taskWithoutCurrentRun: true,
		logManifestOutputs: []string{
			`{"run_ref":"run-16","current_run":"run-16","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":true,"artifacts":[]}`,
			`{"run_ref":"run-16","current_run":"run-16","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":false,"artifacts":[]}`,
		},
	}
	t.Setenv("A2O_RUNTIME_RUN_ONCE_HOST_ROOT", filepath.Join(tempDir, "host-root"))
	t.Setenv("A2O_BUNDLE_STORAGE_DIR", "/var/lib/a3/test-runtime")
	t.Setenv("A2O_RUNTIME_RUN_ONCE_REFERENCE_PACKAGE", packageDir)

	var stdout bytes.Buffer
	withChdir(t, tempDir, func() {
		if err := runRuntimeLogs([]string{"--follow", "--poll-interval", "1ms", "A2O#16"}, runner, &stdout, io.Discard); err != nil {
			t.Fatal(err)
		}
	})

	output := stdout.String()
	if !strings.Contains(output, "=== phase: implementation (ai-raw-live) task=A2O#16 run=run-16 source=detached_commit:abc ===") {
		t.Fatalf("expected live header, got %q", output)
	}
	if !strings.Contains(output, "live log line") {
		t.Fatalf("expected live log body, got %q", output)
	}
}

func TestRuntimeLogsFollowsLatestActiveRunWhenTaskCurrentRunIsStale(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	liveLogRoot := filepath.Join(tempDir, "host-root", "ai-raw-logs")
	liveLogPath := filepath.Join(liveLogRoot, "A2O-16", "implementation.log")
	if err := os.MkdirAll(filepath.Dir(liveLogPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(liveLogPath, []byte("stale current run fallback\n"), 0o644); err != nil {
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
	runner := &fakeRunner{
		staleCurrentRun: true,
		logManifestOutputs: []string{
			`{"run_ref":"run-16","current_run":"run-16","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":true,"artifacts":[]}`,
			`{"run_ref":"run-16","current_run":"run-16","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":false,"artifacts":[]}`,
		},
	}
	t.Setenv("A2O_RUNTIME_RUN_ONCE_HOST_ROOT", filepath.Join(tempDir, "host-root"))
	t.Setenv("A2O_BUNDLE_STORAGE_DIR", "/var/lib/a3/test-runtime")
	t.Setenv("A2O_RUNTIME_RUN_ONCE_REFERENCE_PACKAGE", packageDir)

	var stdout bytes.Buffer
	withChdir(t, tempDir, func() {
		if err := runRuntimeLogs([]string{"--follow", "--poll-interval", "1ms", "A2O#16"}, runner, &stdout, io.Discard); err != nil {
			t.Fatal(err)
		}
	})

	output := stdout.String()
	if !strings.Contains(output, "=== phase: implementation (ai-raw-live) task=A2O#16 run=run-16 source=detached_commit:abc ===") {
		t.Fatalf("expected live header, got %q", output)
	}
	if !strings.Contains(output, "stale current run fallback") {
		t.Fatalf("expected live log body, got %q", output)
	}
}

func TestRuntimeLogsAcceptsFollowAfterTaskRef(t *testing.T) {
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
	runner := &fakeRunner{
		logManifestOutputs: []string{
			`{"run_ref":"run-16","current_run":"run-16","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":true,"live_mode":"ai-raw-log","artifacts":[]}`,
			`{"run_ref":"run-16","current_run":"run-16","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":false,"live_mode":"ai-raw-log","artifacts":[]}`,
		},
	}
	liveRoot := filepath.Join(tempDir, runtimeHostAgentRelativePath, "ai-raw-logs", "Sample-42")
	if err := os.MkdirAll(liveRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(liveRoot, "implementation.log"), []byte("live output\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "logs", "Sample#42", "--follow"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	if !strings.Contains(stdout.String(), "=== phase: implementation (ai-raw-live) task=Sample#42 run=run-16") {
		t.Fatalf("runtime logs should follow after task ref, got:\n%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "live output") {
		t.Fatalf("runtime logs should print live output, got:\n%s", stdout.String())
	}
}

func TestRuntimeWatchSummaryRunsContainerSummaryWithKanbanContext(t *testing.T) {
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
	paths := schedulerPaths(runtimeInstanceConfig{WorkspaceRoot: tempDir})
	if err := os.MkdirAll(paths.Dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.PIDFile, []byte("12345\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.CommandFile, []byte("a2o runtime loop --interval 60s\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runner.processCommands = map[int]string{12345: "a2o runtime loop --interval 60s"}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "watch-summary"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	if !strings.Contains(stdout.String(), "Scheduler: running") {
		t.Fatalf("watch-summary should print existing summary output, got:\n%s", stdout.String())
	}
	joined := strings.Join(runner.joinedCalls(), "\n")
	for _, want := range []string{
		"docker compose -p a3-test -f compose.yml exec -T a2o-runtime a3 watch-summary --storage-backend json --storage-dir /var/lib/a3/test-runtime",
		"--kanban-command python3 --kanban-command-arg /opt/a2o/share/tools/kanban/cli.py --kanban-command-arg --backend --kanban-command-arg soloboard --kanban-command-arg --base-url --kanban-command-arg http://soloboard:3000",
		"--kanban-project A2OReferenceMultiRepo --kanban-status To do --kanban-working-dir /workspace",
		"--kanban-repo-label repo:catalog=repo_alpha",
		"--kanban-repo-label repo:storefront=repo_beta",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("watch-summary missing call fragment %q in:\n%s", want, joined)
		}
	}
}

func TestRuntimeSkillFeedbackListUsesRuntimeStorage(t *testing.T) {
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
		code := run([]string{"runtime", "skill-feedback", "list"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	if !strings.Contains(stdout.String(), "skill_feedback task=A2O#16 run=run-16 phase=implementation category=missing_context target=project_skill") {
		t.Fatalf("skill feedback list should print runtime output, got:\n%s", stdout.String())
	}
	joined := strings.Join(runner.joinedCalls(), "\n")
	want := "docker compose -p a3-test -f compose.yml exec -T a2o-runtime a3 skill-feedback-list --storage-backend json --storage-dir /var/lib/a3/test-runtime"
	if !strings.Contains(joined, want) {
		t.Fatalf("skill feedback list missing call %q in:\n%s", want, joined)
	}
}

func TestRuntimeSkillFeedbackProposeUsesRuntimeStorage(t *testing.T) {
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
		code := run([]string{"runtime", "skill-feedback", "propose", "--state", "accepted", "--target", "project_skill", "--format", "patch"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	if !strings.Contains(stdout.String(), "skill_feedback task=A2O#16 run=run-16 phase=implementation category=missing_context target=project_skill") {
		t.Fatalf("skill feedback propose should print runtime output, got:\n%s", stdout.String())
	}
	joined := strings.Join(runner.joinedCalls(), "\n")
	want := "docker compose -p a3-test -f compose.yml exec -T a2o-runtime a3 skill-feedback-propose --storage-backend json --storage-dir /var/lib/a3/test-runtime --state accepted --target project_skill --format patch"
	if !strings.Contains(joined, want) {
		t.Fatalf("skill feedback propose missing call %q in:\n%s", want, joined)
	}
}

func TestRuntimeWatchSummaryShowsStoppedWhenSchedulerPIDFileIsMissing(t *testing.T) {
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
		code := run([]string{"runtime", "watch-summary"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	if !strings.Contains(stdout.String(), "Scheduler: stopped") {
		t.Fatalf("watch-summary should surface stopped scheduler, got:\n%s", stdout.String())
	}
}

func TestRuntimeWatchSummaryShowsStaleWhenSchedulerProcessIsNotRunning(t *testing.T) {
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
	paths := schedulerPaths(runtimeInstanceConfig{WorkspaceRoot: tempDir})
	if err := os.MkdirAll(paths.Dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.PIDFile, []byte("12345\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.CommandFile, []byte("a2o runtime loop --interval 60s\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "watch-summary"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	if !strings.Contains(stdout.String(), "Scheduler: stale") {
		t.Fatalf("watch-summary should surface stale scheduler, got:\n%s", stdout.String())
	}
}

func TestRuntimeWatchSummaryPreservesPausedSummaryWithoutLiveSchedulerProcess(t *testing.T) {
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
	paths := schedulerPaths(runtimeInstanceConfig{WorkspaceRoot: tempDir})
	if err := os.MkdirAll(paths.Dir, 0o755); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{
		watchSummaryOutput: "Scheduler: paused\nTask Tree\nNext\nRunning\n",
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "watch-summary"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	if !strings.Contains(stdout.String(), "Scheduler: paused") {
		t.Fatalf("watch-summary should preserve paused scheduler state, got:\n%s", stdout.String())
	}
	if strings.Contains(stdout.String(), "Scheduler: stopped") {
		t.Fatalf("watch-summary should not rewrite paused scheduler state to stopped, got:\n%s", stdout.String())
	}
}

func TestTopLevelWatchSummaryIsNotPublicAlias(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{"watch-summary"}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("top-level watch-summary alias should not succeed")
	}
	if !strings.Contains(stderr.String(), "unknown command: watch-summary") {
		t.Fatalf("stderr should reject top-level alias, got %q", stderr.String())
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
		"operator_logs runtime_log=/tmp/a2o-runtime-run-once.log server_log=/tmp/a2o-runtime-run-once-agent-server.log host_agent_log=",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("describe-task missing %q in:\n%s", want, output)
		}
	}
}

func TestRunHostAgentLoopPreservesExistingLogAcrossRestarts(t *testing.T) {
	tempDir := t.TempDir()
	hostAgentLog := filepath.Join(tempDir, ".work", "a2o", "runtime-host-agent", "agent.log")
	if err := os.MkdirAll(filepath.Dir(hostAgentLog), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(hostAgentLog, []byte("previous session\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	config := runtimeInstanceConfig{RuntimeService: "a2o-runtime"}
	plan := runtimeRunOncePlan{
		ComposePrefix:   []string{"compose", "-p", "a3-test", "-f", "compose.yml"},
		AgentAttempts:   1,
		AgentPort:       "7394",
		HostAgentBin:    "a2o-agent",
		HostAgentLog:    hostAgentLog,
		RuntimeExitFile: "/tmp/a2o-runtime-run-once.exit",
	}
	runner := &fakeRunner{}
	var stdout bytes.Buffer

	if err := runHostAgentLoop(config, plan, runner, &stdout); err != nil {
		t.Fatalf("first loop failed: %v", err)
	}
	if err := runHostAgentLoop(config, plan, runner, &stdout); err != nil {
		t.Fatalf("second loop failed: %v", err)
	}

	body, err := os.ReadFile(hostAgentLog)
	if err != nil {
		t.Fatal(err)
	}
	text := string(body)
	if !strings.Contains(text, "previous session\n") {
		t.Fatalf("existing log content should be preserved, got:\n%s", text)
	}
	if count := strings.Count(text, "===== host agent session start "); count != 2 {
		t.Fatalf("expected two session headers, got %d in:\n%s", count, text)
	}
	if count := strings.Count(text, "===== host agent attempt 001 "); count != 2 {
		t.Fatalf("expected two attempt headers, got %d in:\n%s", count, text)
	}
}

func TestRuntimeLoopPreservesHostAgentLogAcrossRunOnceCycles(t *testing.T) {
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
		AgentPort:      "7394",
		StorageDir:     "/var/lib/a3/test-runtime",
	})

	hostAgentLog := filepath.Join(tempDir, ".work", "a2o", "runtime-host-agent", "agent.log")
	if err := os.MkdirAll(filepath.Dir(hostAgentLog), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(hostAgentLog, []byte("before loop\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "loop", "--interval", "0s", "--max-cycles", "2", "--agent-attempts", "1", "--agent-poll-interval", "4s"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	body, err := os.ReadFile(hostAgentLog)
	if err != nil {
		t.Fatal(err)
	}
	text := string(body)
	if !strings.Contains(text, "before loop\n") {
		t.Fatalf("existing log content should be preserved, got:\n%s", text)
	}
	if count := strings.Count(text, "===== host agent session start "); count != 2 {
		t.Fatalf("expected two session headers across loop cycles, got %d in:\n%s", count, text)
	}
	if !strings.Contains(text, "poll_interval=4s") {
		t.Fatalf("expected host agent log to include configured poll interval, got:\n%s", text)
	}
	if !strings.Contains(stdout.String(), "kanban_loop_finished cycles=2") {
		t.Fatalf("runtime loop should finish two cycles, got %q", stdout.String())
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

func TestRuntimeResumeRejectsInvalidOptionsBeforeBackgroundLaunch(t *testing.T) {
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
		code := run([]string{"runtime", "resume", "--interval", "not-a-duration"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail for invalid interval")
		}
	})

	if strings.Contains(strings.Join(runner.joinedCalls(), "\n"), "start-background") {
		t.Fatalf("runtime resume should fail before background launch, got:\n%s", strings.Join(runner.joinedCalls(), "\n"))
	}
	if !strings.Contains(stderr.String(), "parse --interval") {
		t.Fatalf("stderr should mention invalid interval, got %q", stderr.String())
	}
}

func TestRuntimeResumeRejectsNegativeIntervalBeforeBackgroundLaunch(t *testing.T) {
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
		code := run([]string{"runtime", "resume", "--interval", "-1s"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail for negative interval")
		}
	})

	if strings.Contains(strings.Join(runner.joinedCalls(), "\n"), "start-background") {
		t.Fatalf("runtime resume should fail before background launch, got:\n%s", strings.Join(runner.joinedCalls(), "\n"))
	}
	if !strings.Contains(stderr.String(), "--interval must be >= 0") {
		t.Fatalf("stderr should mention negative interval, got %q", stderr.String())
	}
}

func TestRuntimeResumeRequiresProjectConfigBeforeBackgroundLaunch(t *testing.T) {
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
		code := run([]string{"runtime", "resume"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail without project.yaml")
		}
	})

	if !strings.Contains(stderr.String(), "project package config not found") {
		t.Fatalf("stderr should mention missing project.yaml, got %q", stderr.String())
	}
	if strings.Contains(strings.Join(runner.joinedCalls(), "\n"), "start-background") {
		t.Fatalf("runtime resume should fail before background launch, got:\n%s", strings.Join(runner.joinedCalls(), "\n"))
	}
}

func TestRuntimeResumeOnRunningSchedulerUnpausesWithoutLaunchingDuplicate(t *testing.T) {
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
		code := run([]string{"runtime", "resume"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run should succeed when scheduler is already running, stderr=%s", stderr.String())
		}
	})

	if strings.Contains(strings.Join(runner.joinedCalls(), "\n"), "start-background") {
		t.Fatalf("runtime resume should not launch a duplicate scheduler, got:\n%s", strings.Join(runner.joinedCalls(), "\n"))
	}
	assertCallContains(t, runner.joinedCalls(), "docker compose -p a3-test -f compose.yml exec -T a2o-runtime a3 resume-scheduler --storage-backend json --storage-dir /var/lib/a2o/a2o-runtime")
	if !strings.Contains(stdout.String(), "runtime_scheduler_resumed pid=12345 paused=false") {
		t.Fatalf("stdout should report resumed running scheduler, got %q", stdout.String())
	}
}

func TestRuntimeResumeRestoresPausedStateWhenBackgroundLaunchFails(t *testing.T) {
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
	runner := &fakeRunner{
		schedulerPaused:    true,
		startBackgroundErr: errors.New("background launch failed"),
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "resume"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail when background launch fails")
		}
	})

	if !strings.Contains(stderr.String(), "background launch failed") {
		t.Fatalf("stderr should mention launch failure, got %q", stderr.String())
	}
	if !runner.schedulerPaused {
		t.Fatalf("scheduler paused state should be restored after failed resume")
	}
	joined := strings.Join(runner.joinedCalls(), "\n")
	if !strings.Contains(joined, "a3 resume-scheduler --storage-backend json --storage-dir /var/lib/a2o/a2o-runtime") {
		t.Fatalf("resume should clear pause before launch attempt, got:\n%s", joined)
	}
	if !strings.Contains(joined, "a3 pause-scheduler --storage-backend json --storage-dir /var/lib/a2o/a2o-runtime") {
		t.Fatalf("resume should restore pause on launch failure, got:\n%s", joined)
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
		"runtime_scheduler paused=false stop_reason=idle executed_count=0",
		"runtime_package=" + packageDir,
		"kanban_url=http://localhost:3470/",
		"runtime_status_check name=runtime_container status=running container=runtime-container",
		"runtime_status_check name=kanban_service status=running container=soloboard-container",
		"runtime_image_digest=ghcr.io/wamukat/a2o-engine@sha256:test",
		"runtime_image_pinned_ref=ghcr.io/wamukat/a2o-engine@sha256:pinned",
		"runtime_image_local_latest_ref=ghcr.io/wamukat/a2o-engine:latest",
		"runtime_image_running_container=runtime-container image_id=running-image-123 digest=ghcr.io/wamukat/a2o-engine@sha256:test",
		"runtime_image_latest_status=current action=none",
		"runtime_image_running_status=current action=none",
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
	for _, want := range []string{
		"runtime_image_pinned_ref=ghcr.io/wamukat/a2o-engine@sha256:pinned",
		"runtime_image_pinned_digest=ghcr.io/wamukat/a2o-engine@sha256:test",
		"runtime_image_local_latest_ref=ghcr.io/wamukat/a2o-engine:latest",
		"runtime_image_local_latest_digest=ghcr.io/wamukat/a2o-engine@sha256:test",
		"runtime_image_running_container=runtime-container image_id=running-image-123 digest=ghcr.io/wamukat/a2o-engine@sha256:test",
		"runtime_image_latest_status=current action=none",
		"runtime_image_running_status=current action=none",
	} {
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("stdout should include %q in:\n%s", want, stdout.String())
		}
	}
	if runner.lastEnv["A3_RUNTIME_IMAGE"] != "ghcr.io/wamukat/a2o-engine@sha256:pinned" {
		t.Fatalf("image-digest should evaluate compose with runtime image env, got %#v", runner.lastEnv)
	}
}

func TestRuntimeImageDigestUsesInstanceRuntimeImageWhenEnvIsAbsent(t *testing.T) {
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
		RuntimeImage:   "ghcr.io/wamukat/a2o-engine@sha256:instance",
	})
	runner := &fakeRunner{
		imageInspectDigests: map[string]string{
			"image-123": "ghcr.io/wamukat/a2o-engine@sha256:instance",
		},
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "image-digest"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	output := stdout.String()
	for _, want := range []string{
		"runtime_image_pinned_ref=ghcr.io/wamukat/a2o-engine@sha256:instance",
		"runtime_image_pinned_digest=ghcr.io/wamukat/a2o-engine@sha256:instance",
		"runtime_image_local_latest_ref=ghcr.io/wamukat/a2o-engine:latest",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("stdout should include %q in:\n%s", want, output)
		}
	}
	if runner.lastEnv["A2O_RUNTIME_IMAGE"] != "ghcr.io/wamukat/a2o-engine@sha256:instance" {
		t.Fatalf("image-digest should evaluate compose with instance runtime image env, got %#v", runner.lastEnv)
	}
}

func TestUpgradeCheckReportsCheckOnlyPlan(t *testing.T) {
	oldVersion := version
	version = "0.5.test"
	defer func() { version = oldVersion }()
	oldPackagedRuntimeImageReferenceFunc := packagedRuntimeImageReferenceFunc
	packagedRuntimeImageReferenceFunc = func() string {
		return "ghcr.io/wamukat/a2o-engine@sha256:packaged"
	}
	defer func() { packagedRuntimeImageReferenceFunc = oldPackagedRuntimeImageReferenceFunc }()
	dockerConfigDir := t.TempDir()
	t.Setenv("DOCKER_CONFIG", dockerConfigDir)

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
		"  name: upgrade-sample",
		"kanban:",
		"  project: UpgradeSample",
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
		ComposeProject: "a2o-upgrade",
		RuntimeService: "a2o-runtime",
		SoloBoardPort:  "3480",
		RuntimeImage:   "ghcr.io/wamukat/a2o-engine@sha256:instance",
	})
	agentPath := filepath.Join(tempDir, hostAgentBinRelativePath)
	if err := os.MkdirAll(filepath.Dir(agentPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(agentPath, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{
		imageInspectDigests: map[string]string{
			"image-123": "ghcr.io/wamukat/a2o-engine@sha256:instance",
		},
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"upgrade", "check"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	output := stdout.String()
	for _, want := range []string{
		"upgrade_check mode=check-only apply_supported=false",
		"host_launcher_version=0.5.test",
		"runtime_package=" + packageDir,
		"compose_project=a2o-upgrade",
		"kanban_url=http://localhost:3480/",
		"runtime_image_instance_ref=ghcr.io/wamukat/a2o-engine@sha256:instance",
		"runtime_image_packaged_ref=ghcr.io/wamukat/a2o-engine@sha256:packaged",
		"runtime_image_package_status=stale action=run a2o project bootstrap, then a2o runtime up --pull after confirming the desired pin",
		"runtime_image_pinned_ref=ghcr.io/wamukat/a2o-engine@sha256:instance",
		"runtime_image_pinned_digest=ghcr.io/wamukat/a2o-engine@sha256:instance",
		"upgrade_agent status=installed path=" + agentPath + " action=none",
		"upgrade_doctor_begin",
		"doctor_check name=project_package status=ok",
		"doctor_status=ok",
		"upgrade_doctor_status=ok exit_code=0",
		"upgrade_next 1 command=a2o runtime image-digest",
		"upgrade_next 2 command=a2o runtime up --pull",
		"upgrade_next 3 command=a2o agent install --target auto --output " + shellQuote(agentPath),
		"upgrade_next 4 command=a2o doctor",
		"upgrade_next 5 command=a2o runtime status",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("upgrade check missing %q in:\n%s", want, output)
		}
	}
	if runner.lastEnv["A2O_RUNTIME_IMAGE"] != "ghcr.io/wamukat/a2o-engine@sha256:instance" {
		t.Fatalf("upgrade check should evaluate compose with instance runtime image env, got %#v", runner.lastEnv)
	}
	forbidden := " up "
	if strings.Contains(strings.Join(runner.joinedCalls(), "\n"), forbidden+"-d") {
		t.Fatalf("upgrade check should not start services, calls:\n%s", strings.Join(runner.joinedCalls(), "\n"))
	}
}

func TestRuntimeImageDigestShowsLatestAndRunningMismatches(t *testing.T) {
	t.Setenv("A2O_RUNTIME_IMAGE", "ghcr.io/wamukat/a2o-engine@sha256:pinned")
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
	runner := &fakeRunner{
		containerImageIDs: map[string]string{
			"runtime-container": "running-image-123",
		},
		imageInspectDigests: map[string]string{
			"image-123":                         "ghcr.io/wamukat/a2o-engine@sha256:pinned",
			"ghcr.io/wamukat/a2o-engine:latest": "ghcr.io/wamukat/a2o-engine@sha256:latest",
			"running-image-123":                 "ghcr.io/wamukat/a2o-engine@sha256:running",
		},
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "image-digest"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	for _, want := range []string{
		"runtime_image_pinned_digest=ghcr.io/wamukat/a2o-engine@sha256:pinned",
		"runtime_image_local_latest_digest=ghcr.io/wamukat/a2o-engine@sha256:latest",
		"runtime_image_running_container=runtime-container image_id=running-image-123 digest=ghcr.io/wamukat/a2o-engine@sha256:running",
		"runtime_image_latest_status=mismatch action=validate local latest, then update the package runtime image pin if you want this version",
		"runtime_image_running_status=mismatch action=restart runtime with a2o runtime up after confirming the desired pinned digest",
	} {
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("stdout should include %q in:\n%s", want, stdout.String())
		}
	}
}

func TestRuntimeImageDigestReportsUnavailableWithoutFailing(t *testing.T) {
	t.Setenv("A2O_RUNTIME_IMAGE", "registry.example.com/team/a2o-runtime@sha256:pinned")
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
	runner := &fakeRunner{
		containerImageIDs: map[string]string{
			"runtime-container": "running-image-123",
		},
		imageInspectDigests: map[string]string{
			"image-123": "",
			"registry.example.com/team/a2o-runtime:latest": "",
			"running-image-123":                            "",
		},
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "image-digest"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run should report unavailable digest without failing, code=%d stderr=%s stdout=%s", code, stderr.String(), stdout.String())
		}
	})

	for _, want := range []string{
		"runtime_image_digest=unavailable",
		"runtime_image_pinned_ref=registry.example.com/team/a2o-runtime@sha256:pinned",
		"runtime_image_pinned_digest=unavailable",
		"runtime_image_local_latest_ref=registry.example.com/team/a2o-runtime:latest",
		"runtime_image_local_latest_digest=unavailable",
		"runtime_image_running_container=runtime-container image_id=running-image-123 digest=unavailable",
		"runtime_image_latest_status=unknown action=pull registry.example.com/team/a2o-runtime:latest or inspect the configured runtime image, then rerun a2o runtime image-digest",
		"runtime_image_running_status=unknown action=run a2o runtime up, then rerun a2o runtime status",
	} {
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("stdout should include %q in:\n%s", want, stdout.String())
		}
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

func TestRuntimePauseMarksSchedulerPausedWithoutStoppingCurrentProcess(t *testing.T) {
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
		code := run([]string{"runtime", "pause"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	assertCallContains(t, runner.joinedCalls(), "process-running 12345")
	assertCallContains(t, runner.joinedCalls(), "process-command 12345")
	assertCallContains(t, runner.joinedCalls(), "docker compose -p a3-test -f compose.yml exec -T a2o-runtime a3 pause-scheduler --storage-backend json --storage-dir /var/lib/a2o/a2o-runtime")
	if runner.callCount("terminate-process-group 12345") != 0 {
		t.Fatalf("runtime pause must not terminate the scheduler, got:\n%s", strings.Join(runner.joinedCalls(), "\n"))
	}
	if _, err := os.Stat(paths.PIDFile); err != nil {
		t.Fatalf("pid file should be preserved, stat err=%v", err)
	}
	if _, err := os.Stat(paths.CommandFile); err != nil {
		t.Fatalf("command file should be preserved, stat err=%v", err)
	}
	if !strings.Contains(stdout.String(), "runtime_scheduler_paused pid=12345") {
		t.Fatalf("stdout should report scheduler pause, got %q", stdout.String())
	}
}

func TestRuntimePauseDoesNotTerminateUnrelatedReusedPID(t *testing.T) {
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
		code := run([]string{"runtime", "pause"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	if runner.callCount("terminate-process-group 12345") != 0 {
		t.Fatalf("runtime pause must not terminate unrelated process, got:\n%s", strings.Join(runner.joinedCalls(), "\n"))
	}
	assertCallContains(t, runner.joinedCalls(), "docker compose -p a3-test -f compose.yml exec -T a2o-runtime a3 pause-scheduler --storage-backend json --storage-dir /var/lib/a2o/a2o-runtime")
	if _, err := os.Stat(paths.PIDFile); err != nil {
		t.Fatalf("pid file should remain after pause, stat err=%v", err)
	}
	if _, err := os.Stat(paths.CommandFile); err != nil {
		t.Fatalf("command file should remain after pause, stat err=%v", err)
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
  max_steps: 7
  agent_attempts: 9
  agent_poll_interval: 5s
  agent_control_plane_connect_timeout: 3s
  agent_control_plane_request_timeout: 25s
  agent_control_plane_retry_count: 4
  agent_control_plane_retry_delay: 1500ms
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
	if !strings.Contains(joined, "'--agent-env' 'A2O_WORKER_LAUNCHER_CONFIG_PATH="+launcherPath+"'") {
		t.Fatalf("run-once should pass launcher config path to agent jobs, calls:\n%s", joined)
	}
	if runner.lastEnv["A3_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS"] != "" {
		t.Fatalf("agent attempts should come from package plan, not env override, got %q", runner.lastEnv["A3_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS"])
	}
	for _, want := range []string{
		"-control-plane-connect-timeout 3s",
		"-control-plane-request-timeout 25s",
		"-control-plane-retries 4",
		"-control-plane-retry-delay 1.5s",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("run-once should pass host agent control plane setting %q, got:\n%s", want, joined)
		}
	}
	if !strings.Contains(stdout.String(), "runtime_host_agent_loop attempts=9 poll_interval=5s") {
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

func TestRuntimeRunOnceRepairsStaleRunsOnStartupAndAttemptBudgetExhaustion(t *testing.T) {
	t.Setenv("A3_RUNTIME_RUN_ONCE_ARCHIVE_STATE", "1")
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
	runner := &fakeRunner{runtimeExitMissing: true}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "run-once", "--max-steps", "1", "--agent-attempts", "2"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail when runtime exit file is never written")
		}
	})

	output := stdout.String()
	if !strings.Contains(output, "runtime_repair_runs reason=startup") {
		t.Fatalf("run-once should repair stale runs before starting, got:\n%s", output)
	}
	if !strings.Contains(output, "runtime_repair_runs reason=agent_attempt_budget_exhausted") {
		t.Fatalf("run-once should repair active runs after agent attempt exhaustion, got:\n%s", output)
	}
	if count := runner.callCountContains("a3 repair-runs --storage-backend json --storage-dir /var/lib/a3/test-runtime --apply"); count != 2 {
		t.Fatalf("repair-runs call count=%d, want 2\ncalls:\n%s", count, strings.Join(runner.joinedCalls(), "\n"))
	}
	startupRepairIndex := firstCallIndexContains(runner.joinedCalls(), "a3 repair-runs --storage-backend json --storage-dir /var/lib/a3/test-runtime --apply")
	archiveMoveIndex := firstCallIndexContains(runner.joinedCalls(), " mv /var/lib/a3/test-runtime ")
	if startupRepairIndex < 0 || archiveMoveIndex < 0 || startupRepairIndex > archiveMoveIndex {
		t.Fatalf("startup repair should run before archive moves storage, repair=%d archive=%d\ncalls:\n%s", startupRepairIndex, archiveMoveIndex, strings.Join(runner.joinedCalls(), "\n"))
	}
	if !strings.Contains(stderr.String(), "runtime run-once did not finish within 2 agent attempts") {
		t.Fatalf("stderr should report attempt exhaustion, got %q", stderr.String())
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
			"A2O_ROOT_DIR":         "/workspace",
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
		"export A2O_BRANCH_NAMESPACE='branch with space' A2O_ROOT_DIR='/workspace' A3_SECRET=${A3_SECRET:-a2o-runtime-secret}",
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

func writeAgentPackageDir(t *testing.T, root string, binaries map[string]string) string {
	t.Helper()
	packageDir := filepath.Join(root, "packages")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(packageDir, "release-manifest.jsonl")
	compatibilityPath := filepath.Join(packageDir, "package-compatibility.json")
	manifestLines := make([]string, 0, len(binaries))
	for target, body := range binaries {
		targetDir := filepath.Join(packageDir, target)
		if err := os.MkdirAll(targetDir, 0o755); err != nil {
			t.Fatal(err)
		}
		launcherPath := filepath.Join(targetDir, "a3")
		if err := os.WriteFile(launcherPath, []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
		archiveName := fmt.Sprintf("a3-agent-%s-%s.tar.gz", version, target)
		archivePath := filepath.Join(packageDir, archiveName)
		writeAgentArchiveFile(t, archivePath, body)
		sum := sha256.Sum256(mustReadTestFile(t, archivePath))
		goos, goarch, _ := strings.Cut(target, "-")
		entry := map[string]string{
			"version": version,
			"goos":    goos,
			"goarch":  goarch,
			"archive": archiveName,
			"sha256":  fmt.Sprintf("%x", sum[:]),
		}
		entryJSON, err := json.Marshal(entry)
		if err != nil {
			t.Fatal(err)
		}
		manifestLines = append(manifestLines, string(entryJSON))
	}
	if err := os.WriteFile(manifestPath, []byte(strings.Join(manifestLines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	contract := map[string]any{
		"schema":           "a2o-agent-package-compatibility/v1",
		"package_version":  version,
		"runtime_version":  version,
		"archive_manifest": "release-manifest.jsonl",
		"launcher_layout":  "platform-bin-dir-v1",
	}
	body, err := json.Marshal(contract)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(compatibilityPath, body, 0o644); err != nil {
		t.Fatal(err)
	}
	return packageDir
}

func writeAgentArchiveFile(t *testing.T, path, body string) {
	t.Helper()
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	gzipWriter := gzip.NewWriter(file)
	tarWriter := tar.NewWriter(gzipWriter)
	content := []byte(body)
	header := &tar.Header{Name: "a3-agent", Mode: 0o755, Size: int64(len(content))}
	if err := tarWriter.WriteHeader(header); err != nil {
		t.Fatal(err)
	}
	if _, err := tarWriter.Write(content); err != nil {
		t.Fatal(err)
	}
	if err := tarWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gzipWriter.Close(); err != nil {
		t.Fatal(err)
	}
}

func mustReadTestFile(t *testing.T, path string) []byte {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return body
}

type fakeRunner struct {
	calls                  [][]string
	emptyContainer         bool
	failShowTask           bool
	taskWithoutCurrentRun  bool
	staleCurrentRun        bool
	runtimeExitMissing     bool
	legacyRuntimeOrphans   []string
	failLegacyRuntimeRM    bool
	missingRunHistory      bool
	schedulerPaused        bool
	schedulerStopReason    string
	schedulerExecutedCount int
	startBackgroundErr     error
	err                    error
	lastEnv                map[string]string
	nextPID                int
	processCommands        map[int]string
	errorOutput            string
	imageInspectDigests    map[string]string
	containerImageIDs      map[string]string
	logManifestOutput      string
	logManifestOutputs     []string
	watchSummaryOutput     string
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
	case strings.Contains(joined, " a3 pause-scheduler "):
		r.schedulerPaused = true
		return []byte("scheduler paused=true\n"), nil
	case strings.Contains(joined, " a3 resume-scheduler "):
		r.schedulerPaused = false
		return []byte("scheduler paused=false\n"), nil
	case strings.Contains(joined, " a3 show-scheduler-state "):
		stopReason := r.schedulerStopReason
		if stopReason == "" {
			stopReason = "idle"
		}
		return []byte(fmt.Sprintf("scheduler paused=%t stop_reason=%s executed_count=%d\n", r.schedulerPaused, stopReason, r.schedulerExecutedCount)), nil
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
	case name == "docker" && len(args) >= 4 && args[0] == "inspect":
		if imageID, ok := r.containerImageIDs[args[1]]; ok {
			return []byte(imageID + "\n"), nil
		}
		return []byte("running-image-123\n"), nil
	case name == "docker" && len(args) >= 4 && args[0] == "image" && args[1] == "inspect":
		if digest, ok := r.imageInspectDigests[args[2]]; ok {
			return []byte(digest + "\n"), nil
		}
		return []byte("ghcr.io/wamukat/a2o-engine@sha256:test\n"), nil
	case strings.Contains(joined, " compose ") && strings.Contains(joined, " ps -q "):
		if r.emptyContainer {
			return []byte("\n"), nil
		}
		return []byte("container-123\n"), nil
	case strings.Contains(joined, " exec -T ") && strings.Contains(joined, " test -f /tmp/a2o-runtime-run-once.exit"):
		if r.runtimeExitMissing {
			return []byte("missing\n"), errors.New("missing")
		}
		return []byte{}, nil
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
		if r.staleCurrentRun {
			return []byte("task A2O#16 kind=single status=blocked current_run=run-stale\nedit_scope=repo_alpha\nverification_scope=repo_alpha\n"), nil
		}
		return []byte("task A2O#16 kind=single status=blocked current_run=run-16\nedit_scope=repo_alpha\nverification_scope=repo_alpha\n"), nil
	case strings.Contains(joined, " ruby -rjson -e ") && strings.Contains(joined, "runtime_latest_run"):
		return []byte("runtime_latest_run run_ref=run-16 task_ref=A2O#16 phase=implementation state=terminal outcome=blocked\n"), nil
	case strings.Contains(joined, " ruby -rjson -e ") && strings.Contains(joined, "phase_records"):
		if len(r.logManifestOutputs) > 0 {
			output := r.logManifestOutputs[0]
			r.logManifestOutputs = r.logManifestOutputs[1:]
			return []byte(output + "\n"), nil
		}
		if r.logManifestOutput != "" {
			return []byte(r.logManifestOutput + "\n"), nil
		}
		return []byte(`{"run_ref":"run-16","current_run":"run-16","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":false,"artifacts":[{"phase":"implementation","artifact_id":"worker-run-16-implementation-combined-log"}]}` + "\n"), nil
	case strings.Contains(joined, " ruby -rjson -e "):
		return []byte("run-16\n"), nil
	case strings.Contains(joined, "show-run"):
		return []byte("run run-16 task=A2O#16 phase=implementation workspace=runtime_workspace source=detached_commit:abc outcome=blocked\nevidence workspace=runtime_workspace source=detached_commit:abc\nexecution_started_at=2026-04-11T08:00:00Z\nexecution_finished_at=2026-04-11T08:00:42Z\nexecution_duration_seconds=42.000\nagent_artifact role=combined-log id=worker-run-16-implementation-combined-log retention=analysis media_type=text/plain byte_size=42\nagent_artifact_read=a2o runtime show-artifact worker-run-16-implementation-combined-log\nlatest_blocked phase=implementation summary=executor failed\nblocked_error_category=executor_failed\n"), nil
	case strings.Contains(joined, "agent-artifact-read"):
		return []byte("agent raw log line\n"), nil
	case strings.Contains(joined, "clear-runtime-logs"):
		return []byte("runtime_log_clear=dry_run\nselected_count=1\ndeleted_count=1\nselected_artifact_ids=worker-run-16-implementation-combined-log\n"), nil
	case strings.Contains(joined, " a3 watch-summary "):
		if r.watchSummaryOutput != "" {
			return []byte(r.watchSummaryOutput), nil
		}
		return []byte("Scheduler: running\nTask Tree\nNext\nRunning\n"), nil
	case strings.Contains(joined, "skill-feedback-list") || strings.Contains(joined, "skill-feedback-propose"):
		return []byte("skill_feedback task=A2O#16 run=run-16 phase=implementation category=missing_context target=project_skill\nskill_feedback_summary=Add fixture update guidance.\n"), nil
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
	if r.startBackgroundErr != nil {
		return 0, r.startBackgroundErr
	}
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

func firstCallIndexContains(calls []string, want string) int {
	for index, call := range calls {
		if strings.Contains(call, want) {
			return index
		}
	}
	return -1
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
