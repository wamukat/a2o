package agent

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadRuntimeProfileConfig(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent-profile.json")
	if err := os.WriteFile(path, []byte(`{
  "agent": "dev-env",
  "control_plane_url": "http://a3-runtime:7393",
  "agent_token": "secret-token",
  "workspace_root": "/work/a3-agent",
  "source_aliases": {
    "member-portal-starters": "/src/member-portal-starters"
  }
}`), 0o644); err != nil {
		t.Fatal(err)
	}

	config, err := LoadRuntimeProfileConfig(path)
	if err != nil {
		t.Fatal(err)
	}

	if config.AgentName != "dev-env" {
		t.Fatalf("agent = %s", config.AgentName)
	}
	if config.ControlPlaneURL != "http://a3-runtime:7393" {
		t.Fatalf("control plane url = %s", config.ControlPlaneURL)
	}
	if config.AgentToken != "secret-token" {
		t.Fatalf("agent token = %s", config.AgentToken)
	}
	if config.WorkspaceRoot != "/work/a3-agent" {
		t.Fatalf("workspace root = %s", config.WorkspaceRoot)
	}
	if config.SourceAliases["member-portal-starters"] != "/src/member-portal-starters" {
		t.Fatalf("source aliases = %#v", config.SourceAliases)
	}
}

func TestRuntimeProfileConfigRequiresWorkspaceRootForAliases(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent-profile.json")
	if err := os.WriteFile(path, []byte(`{
  "source_aliases": {
    "member-portal-starters": "/src/member-portal-starters"
  }
}`), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := LoadRuntimeProfileConfig(path); err == nil {
		t.Fatal("expected missing workspace_root failure")
	}
}
