package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRuntimeComposeServicesUseInit(t *testing.T) {
	repoRoot := findRepoRootForComposeTest(t)
	for _, path := range []string{
		filepath.Join(repoRoot, "docker", "compose", "a2o-kanbalone.yml"),
		filepath.Join(repoRoot, "docker", "compose", "a2o-kanbalone.release.yml"),
	} {
		t.Run(filepath.Base(path), func(t *testing.T) {
			body, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			text := string(body)
			serviceIndex := strings.Index(text, "  a2o-runtime:\n")
			if serviceIndex < 0 {
				t.Fatalf("%s does not define a2o-runtime service", path)
			}
			rest := text[serviceIndex+len("  a2o-runtime:\n"):]
			nextServiceIndex := strings.Index(rest, "\n  kanbalone:\n")
			if nextServiceIndex >= 0 {
				rest = rest[:nextServiceIndex]
			}
			if !strings.Contains(rest, "    init: true\n") {
				t.Fatalf("%s a2o-runtime service must set init: true so PID 1 reaps exited child processes", path)
			}
			if !strings.Contains(rest, `command: ["sleep", "infinity"]`) {
				t.Fatalf("%s a2o-runtime service should still keep the long-running runtime container command", path)
			}
		})
	}
}

func TestKanbaloneComposeSupportsRemoteCredentialPassthrough(t *testing.T) {
	repoRoot := findRepoRootForComposeTest(t)
	for _, path := range []string{
		filepath.Join(repoRoot, "docker", "compose", "a2o-kanbalone.yml"),
		filepath.Join(repoRoot, "docker", "compose", "a2o-kanbalone.release.yml"),
	} {
		t.Run(filepath.Base(path), func(t *testing.T) {
			body, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			text := string(body)
			serviceIndex := strings.Index(text, "  kanbalone:\n")
			if serviceIndex < 0 {
				t.Fatalf("%s does not define kanbalone service", path)
			}
			rest := text[serviceIndex+len("  kanbalone:\n"):]
			for _, want := range []string{
				"KANBALONE_REMOTE_CREDENTIALS: ${KANBALONE_REMOTE_CREDENTIALS:-}",
				"GITHUB_TOKEN: ${GITHUB_TOKEN:-}",
			} {
				if !strings.Contains(rest, want) {
					t.Fatalf("%s kanbalone service must support credential passthrough %q", path, want)
				}
			}
		})
	}
}

func findRepoRootForComposeTest(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		candidate := filepath.Join(dir, "docker", "compose", "a2o-kanbalone.yml")
		if _, err := os.Stat(candidate); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("failed to find repository root containing docker/compose/a2o-kanbalone.yml")
		}
		dir = parent
	}
}
