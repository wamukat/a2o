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
  "agent_token_file": "/run/secrets/a3-agent-token",
		"workspace_root": "/work/a3-agent",
		"source_aliases": {
			"sample-catalog-service": "/src/sample-catalog-service"
		},
		"required_bins": ["git", "task"]
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
	if config.AgentTokenFile != "/run/secrets/a3-agent-token" {
		t.Fatalf("agent token file = %s", config.AgentTokenFile)
	}
	if config.WorkspaceRoot != "/work/a3-agent" {
		t.Fatalf("workspace root = %s", config.WorkspaceRoot)
	}
	if config.SourceAliases["sample-catalog-service"] != "/src/sample-catalog-service" {
		t.Fatalf("source aliases = %#v", config.SourceAliases)
	}
	if len(config.RequiredBins) != 2 || config.RequiredBins[0] != "git" {
		t.Fatalf("required bins = %#v", config.RequiredBins)
	}
}

func TestRuntimeProfileConfigRequiresWorkspaceRootForAliases(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent-profile.json")
	if err := os.WriteFile(path, []byte(`{
  "source_aliases": {
    "sample-catalog-service": "/src/sample-catalog-service"
  }
}`), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := LoadRuntimeProfileConfig(path); err == nil {
		t.Fatal("expected missing workspace_root failure")
	}
}

func TestRuntimeProfileConfigRejectsInsecureRemoteHTTP(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent-profile.json")
	if err := os.WriteFile(path, []byte(`{
  "control_plane_url": "http://a3.example.com:7393"
}`), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := LoadRuntimeProfileConfig(path); err == nil {
		t.Fatal("expected insecure remote HTTP failure")
	}
}

func TestRuntimeProfileConfigAllowsLocalAndDockerHTTP(t *testing.T) {
	for _, controlPlaneURL := range []string{
		"http://127.0.0.1:7393",
		"http://localhost:7393",
		"http://a3-runtime:7393",
		"https://a3.example.com",
	} {
		config := RuntimeProfileConfig{ControlPlaneURL: controlPlaneURL}
		if err := config.Validate(); err != nil {
			t.Fatalf("Validate(%s) failed: %v", controlPlaneURL, err)
		}
	}
}
