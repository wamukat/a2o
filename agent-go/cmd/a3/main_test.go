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

func TestRuntimeUpUsesBootstrappedInstanceConfig(t *testing.T) {
	tempDir := t.TempDir()
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    filepath.Join(tempDir, "package"),
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a3-runtime",
		SoloBoardPort:  "3480",
		AgentPort:      "7394",
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
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml build a3-runtime")
	assertCallContains(t, joined, "docker compose -p a3-test -f compose.yml up -d a3-runtime soloboard")
	if !strings.Contains(stdout.String(), "runtime_up compose_project=a3-test") {
		t.Fatalf("stdout should describe runtime up, got %q", stdout.String())
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
}

func (r *fakeRunner) Run(name string, args ...string) ([]byte, error) {
	call := append([]string{name}, args...)
	r.calls = append(r.calls, call)
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

func assertCallContains(t *testing.T, calls []string, want string) {
	t.Helper()
	for _, call := range calls {
		if call == want {
			return
		}
	}
	t.Fatalf("missing call %q in:\n%s", want, strings.Join(calls, "\n"))
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
