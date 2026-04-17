package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
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
		"a3-runtime",
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
	assertCallContains(t, joined, "docker compose -p test-project -f compose.yml build a3-runtime")
	assertCallContains(t, joined, "docker compose -p test-project -f compose.yml up -d --no-deps a3-runtime")
	assertCallContains(t, joined, "docker compose -p test-project -f compose.yml ps -q a3-runtime")
	assertCallContains(t, joined, "docker exec container-123 a3 agent package verify --target darwin-amd64")
	assertCallContains(t, joined, "docker exec container-123 a3 agent package export --target darwin-amd64 --output /tmp/a3-agent-export")
	assertCallContains(t, joined, "docker cp container-123:/tmp/a3-agent-export "+outputPath)
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

	configPath := filepath.Join(tempDir, ".a3", "runtime-instance.json")
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
}

func TestUnsupportedRuntimeCommandsAreNotPublicEntrypoints(t *testing.T) {
	for _, command := range [][]string{
		{"runtime", "up"},
		{"runtime", "down"},
		{"runtime", "start"},
		{"runtime", "stop"},
		{"runtime", "status"},
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
		"a2o kanban up [--build]",
		"a2o kanban doctor",
		"a2o kanban url",
		"a2o runtime doctor",
		"a2o runtime run-once [--max-steps N] [--agent-attempts N]",
		"a2o runtime loop [--interval DURATION] [--max-cycles N]",
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

func TestKanbanUpUsesBootstrappedInstanceConfig(t *testing.T) {
	tempDir := t.TempDir()
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    filepath.Join(tempDir, "package"),
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a3-runtime",
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
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml build a3-runtime")
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml up -d a3-runtime soloboard")
	if !strings.Contains(stdout.String(), "kanban_up compose_project=a3-test url=http://localhost:3480/") {
		t.Fatalf("stdout should describe kanban up, got %q", stdout.String())
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
	outputPath := filepath.Join(tempDir, "bin", "a3-agent")
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    filepath.Join(tempDir, "package"),
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a3-runtime",
	})
	runner := &fakeRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"agent", "install", "--target", "linux-amd64", "--output", outputPath}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	joined := runner.joinedCalls()
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml up -d --no-deps a3-runtime")
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml ps -q a3-runtime")
	assertCallContains(t, joined, "docker exec container-123 a3 agent package verify --target linux-amd64")
}

func TestRuntimeRunOnceUsesBootstrappedInstanceConfig(t *testing.T) {
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
		RuntimeService: "a3-runtime",
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
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml up -d a3-runtime soloboard")
	if hasCallPrefix(joined, "bash "+packageDir) {
		t.Fatalf("run-once should not call project runtime script:\n%s", strings.Join(joined, "\n"))
	}
	if !strings.Contains(stdout.String(), "kanban_run_once=generic") {
		t.Fatalf("stdout should describe generic run-once, got %q", stdout.String())
	}
	if !strings.Contains(strings.Join(joined, "\n"), "a3 execute-until-idle") {
		t.Fatalf("run-once should start execute-until-idle directly, calls:\n%s", strings.Join(joined, "\n"))
	}
	for _, forbidden := range []string{
		"ps -eo pid=,args=",
		"bash -lc cat ",
		"bash -lc echo '--- runtime log tail ---'; tail",
	} {
		if strings.Contains(strings.Join(joined, "\n"), forbidden) {
			t.Fatalf("run-once should use structured cleanup/read/log commands, found %q in:\n%s", forbidden, strings.Join(joined, "\n"))
		}
	}
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml exec -T a3-runtime pgrep -f a3 execute-until-idle")
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml exec -T a3-runtime cat /tmp/a3-runtime-run-once.exit")
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml exec -T a3-runtime tail -n 160 /tmp/a3-runtime-run-once.log")
	if strings.Contains(strings.Join(joined, "\n"), "portal") {
		t.Fatalf("run-once should not use Portal defaults:\n%s", strings.Join(joined, "\n"))
	}
	joinedText := strings.Join(joined, "\n")
	for _, want := range []string{
		"'--kanban-project' 'A2OReferenceMultiRepo'",
		"'--agent-source-path' 'catalog-service=",
		"'--agent-source-path' 'storefront=",
		"'--kanban-repo-label' 'repo:catalog=repo_alpha'",
		"'--repo-source' 'repo_alpha=/workspace/reference-products/multi-repo-fixture/repos/catalog-service'",
	} {
		if !strings.Contains(joinedText, want) {
			t.Fatalf("run-once missing %q in:\n%s", want, joinedText)
		}
	}
	if runner.lastEnv["A3_BUNDLE_COMPOSE_FILE"] != "compose.yml" {
		t.Fatalf("compose env=%q", runner.lastEnv["A3_BUNDLE_COMPOSE_FILE"])
	}
	if runner.lastEnv["A3_BUNDLE_PROJECT"] != "a3-test" {
		t.Fatalf("project env=%q", runner.lastEnv["A3_BUNDLE_PROJECT"])
	}
	if runner.lastEnv["A3_RUNTIME_RUN_ONCE_MAX_STEPS"] != "1" {
		t.Fatalf("max steps env=%q", runner.lastEnv["A3_RUNTIME_RUN_ONCE_MAX_STEPS"])
	}
	if runner.lastEnv["A3_BRANCH_NAMESPACE"] != "a3-test" {
		t.Fatalf("branch namespace env=%q", runner.lastEnv["A3_BRANCH_NAMESPACE"])
	}
	if runner.lastEnv["A3_HOST_AGENT_BIN"] != filepath.Join(tempDir, ".work", "a3-agent", "bin", "a3-agent") {
		t.Fatalf("agent bin env=%q", runner.lastEnv["A3_HOST_AGENT_BIN"])
	}
}

func TestRuntimeRunOncePrefersPublicA2OAgentPath(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	publicAgentPath := filepath.Join(tempDir, ".work", "a2o-agent", "bin", "a2o-agent")
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
		RuntimeService: "a3-runtime",
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
	projectYaml := `project: a2o-reference-typescript-api-web
kanban:
  provider: soloboard
  project: A2OReferenceTypeScript
repos:
  app:
    path: ..
    role: product
agent:
  workspace_root: .work/a2o-agent/workspaces
  required_bins:
    - git
    - node
    - npm
runtime:
  kanban_status: To do
  live_ref: refs/heads/main
  max_steps: 7
  agent_attempts: 9
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
		RuntimeService: "a3-runtime",
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
	t.Setenv("A3_COMPOSE_PROJECT", "env-project")
	t.Setenv("A3_COMPOSE_FILE", "env-compose.yml")
	t.Setenv("A3_BUNDLE_AGENT_PORT", "7555")
	t.Setenv("A3_BUNDLE_STORAGE_DIR", "/var/lib/a3/env-runtime")
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "stale-compose.yml",
		ComposeProject: "stale-project",
		RuntimeService: "a3-runtime",
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
	if !strings.Contains(joined, "docker compose -p env-project -f env-compose.yml up -d a3-runtime soloboard") {
		t.Fatalf("run-once should use env compose override, calls:\n%s", joined)
	}
	if !strings.Contains(joined, "http://127.0.0.1:7555") {
		t.Fatalf("run-once should use env agent port override, calls:\n%s", joined)
	}
	if !strings.Contains(joined, "/var/lib/a3/env-runtime") {
		t.Fatalf("run-once should use env storage override, calls:\n%s", joined)
	}
}

func TestRuntimeLoopRunsConfiguredCycles(t *testing.T) {
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
		RuntimeService: "a3-runtime",
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
			"A3_BRANCH_NAMESPACE": "branch with space",
			"A3_ROOT_DIR":         "/workspace",
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
		"export A3_BRANCH_NAMESPACE='branch with space' A3_ROOT_DIR='/workspace' A3_SECRET=${A3_SECRET:-a2o-runtime-secret}",
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
	config := runtimeInstanceConfig{RuntimeService: "a3-runtime"}
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
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml exec -T a3-runtime mkdir -p /var/lib/a3/archive")
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml exec -T a3-runtime test -e /var/lib/a3/test-runtime")
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml exec -T a3-runtime mv /var/lib/a3/test-runtime /var/lib/a3/archive/test-runtime-20260417T000000Z")
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml exec -T a3-runtime mkdir -p /var/lib/a3/test-runtime")
}

func TestAgentInstallRequiresOutput(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{"agent", "install"}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("run should fail without --output")
	}
	if !strings.Contains(stderr.String(), "--output is required") {
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
	if !strings.Contains(stderr.String(), "runtime container not found") {
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
	if !strings.Contains(stderr.String(), "A3 runtime instance config not found") {
		t.Fatalf("stderr should mention missing instance config, got %q", stderr.String())
	}
}

type fakeRunner struct {
	calls          [][]string
	emptyContainer bool
	err            error
	lastEnv        map[string]string
}

func (r *fakeRunner) Run(name string, args ...string) ([]byte, error) {
	call := append([]string{name}, args...)
	r.calls = append(r.calls, call)
	r.lastEnv = map[string]string{
		"A3_BUNDLE_COMPOSE_FILE":             os.Getenv("A3_BUNDLE_COMPOSE_FILE"),
		"A3_BUNDLE_PROJECT":                  os.Getenv("A3_BUNDLE_PROJECT"),
		"A3_RUNTIME_RUN_ONCE_MAX_STEPS":      os.Getenv("A3_RUNTIME_RUN_ONCE_MAX_STEPS"),
		"A3_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS": os.Getenv("A3_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS"),
		"A3_BRANCH_NAMESPACE":                os.Getenv("A3_BRANCH_NAMESPACE"),
		"A3_HOST_AGENT_BIN":                  os.Getenv("A3_HOST_AGENT_BIN"),
	}
	if r.err != nil {
		return []byte("forced error"), r.err
	}
	joined := strings.Join(call, " ")
	switch {
	case strings.Contains(joined, " compose ") && strings.Contains(joined, " ps -q "):
		if r.emptyContainer {
			return []byte("\n"), nil
		}
		return []byte("container-123\n"), nil
	case strings.Contains(joined, " date -u +%Y%m%dT%H%M%SZ"):
		return []byte("20260417T000000Z\n"), nil
	case strings.Contains(joined, " cat /tmp/a3-runtime-run-once.exit"):
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

func writeTestInstanceConfig(t *testing.T, dir string, config runtimeInstanceConfig) {
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
