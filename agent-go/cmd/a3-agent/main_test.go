package main

import (
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

func TestRenderSystemdServiceTemplate(t *testing.T) {
	output, err := renderServiceTemplate(serviceTemplateOptions{
		Kind:         "systemd",
		Label:        "dev.a3.agent",
		BinaryPath:   "/usr/local/bin/a3-agent",
		ConfigPath:   "/etc/a3/agent-profile.json",
		PollInterval: "2s",
		WorkingDir:   "/var/lib/a3-agent",
	})
	if err != nil {
		t.Fatal(err)
	}
	required := []string{
		"Description=A3 Agent (dev.a3.agent)",
		"WorkingDirectory=/var/lib/a3-agent",
		"ExecStart=/usr/local/bin/a3-agent -config /etc/a3/agent-profile.json --loop --poll-interval 2s",
		"Restart=on-failure",
		"WantedBy=default.target",
	}
	for _, want := range required {
		if !strings.Contains(output, want) {
			t.Fatalf("systemd template does not contain %q:\n%s", want, output)
		}
	}
}

func TestRenderLaunchdServiceTemplate(t *testing.T) {
	output, err := renderServiceTemplate(serviceTemplateOptions{
		Kind:         "launchd",
		Label:        "dev.a3.agent",
		BinaryPath:   "/usr/local/bin/a3-agent",
		ConfigPath:   "/Users/dev/.a3/agent-profile.json",
		PollInterval: "2s",
		WorkingDir:   "/Users/dev/project",
	})
	if err != nil {
		t.Fatal(err)
	}
	required := []string{
		"<key>Label</key>",
		"<string>dev.a3.agent</string>",
		"<string>/usr/local/bin/a3-agent</string>",
		"<string>-config</string>",
		"<string>/Users/dev/.a3/agent-profile.json</string>",
		"<string>--loop</string>",
		"<string>--poll-interval</string>",
		"<string>2s</string>",
		"<key>WorkingDirectory</key>",
		"<string>/Users/dev/project</string>",
		"<key>KeepAlive</key>",
		"<key>RunAtLoad</key>",
	}
	for _, want := range required {
		if !strings.Contains(output, want) {
			t.Fatalf("launchd template does not contain %q:\n%s", want, output)
		}
	}
}

func TestRenderServiceTemplateRejectsInvalidInput(t *testing.T) {
	cases := []serviceTemplateOptions{
		{Kind: "systemd", Label: "dev.a3.agent", BinaryPath: "/usr/local/bin/a3-agent", ConfigPath: "/etc/a3/agent-profile.json", PollInterval: "invalid"},
		{Kind: "unknown", Label: "dev.a3.agent", BinaryPath: "/usr/local/bin/a3-agent", ConfigPath: "/etc/a3/agent-profile.json", PollInterval: "2s"},
		{Kind: "systemd", Label: "dev.a3.agent", BinaryPath: "/usr/local/bin/a3 agent", ConfigPath: "/etc/a3/agent-profile.json", PollInterval: "2s"},
	}
	for _, options := range cases {
		if _, err := renderServiceTemplate(options); err == nil {
			t.Fatalf("renderServiceTemplate(%+v) succeeded, want error", options)
		}
	}
}

func TestRunServiceTemplateAcceptsKindThenFlags(t *testing.T) {
	code := runServiceTemplate([]string{
		"systemd",
		"-config", "/etc/a3/agent-profile.json",
		"-binary", "/usr/local/bin/a3-agent",
		"-poll-interval", "2s",
	})
	if code != 0 {
		t.Fatalf("service-template exit code = %d, want 0", code)
	}
}

func runGit(t *testing.T, root string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v failed: %v: %s", args, err, out)
	}
}
