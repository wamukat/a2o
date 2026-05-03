package main

import (
	"bytes"
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
	outputPath := filepath.Join(tempDir, "bin", "a2o-agent")
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
	assertCallContains(t, joined, "docker exec container-123 a2o agent package verify --target darwin-amd64")
	assertCallContains(t, joined, "docker exec container-123 a2o agent package export --target darwin-amd64 --output /tmp/a2o-agent-export")
	assertCallContains(t, joined, "docker cp container-123:/tmp/a2o-agent-export "+outputPath)
}

func TestAgentInstallExportsAgentFromPackageDir(t *testing.T) {
	tempDir := t.TempDir()
	outputPath := filepath.Join(tempDir, "bin", "a2o-agent")
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
	outputPath := filepath.Join(tempDir, "bin", "a2o-agent")
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
	assertCallContains(t, runner.joinedCalls(), "docker exec container-123 a2o agent package verify --target darwin-amd64")
	if !strings.Contains(stdout.String(), "source=runtime-image") {
		t.Fatalf("stdout should report runtime-image fallback, got %q", stdout.String())
	}
}

func TestAgentInstallFailsWithoutFallbackWhenExplicitPackageDirIsInvalid(t *testing.T) {
	tempDir := t.TempDir()
	outputPath := filepath.Join(tempDir, "bin", "a2o-agent")
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
		filepath.Join(t.TempDir(), "a2o-agent"),
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
		code := run([]string{"agent", "install", "--target", "linux-amd64", "--output", filepath.Join(t.TempDir(), "a2o-agent")}, &fakeRunner{}, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("run should fail without an instance config")
		}
	})
	if !strings.Contains(stderr.String(), "A2O runtime instance config not found") {
		t.Fatalf("stderr should mention missing instance config, got %q", stderr.String())
	}
}
