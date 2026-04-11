package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
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
	sourceRoot := filepath.Join(tmp, "source")
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
	configPath := filepath.Join(tmp, "agent-profile.json")
	if err := os.WriteFile(configPath, []byte(`{
  "agent": "dev-env",
  "control_plane_url": "http://a3-runtime:7393",
  "workspace_root": "`+filepath.ToSlash(filepath.Join(tmp, "workspaces"))+`",
  "source_aliases": {
    "member-portal-starters": "`+filepath.ToSlash(sourceRoot)+`"
  }
}`), 0o644); err != nil {
		t.Fatal(err)
	}

	if code := run([]string{"doctor", "-config", configPath}); code != 0 {
		t.Fatalf("doctor exit code = %d", code)
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

func runGit(t *testing.T, root string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v failed: %v: %s", args, err, out)
	}
}
