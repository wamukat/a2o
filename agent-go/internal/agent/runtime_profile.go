package agent

import (
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"strings"
)

type RuntimeProfileConfig struct {
	AgentName           string            `json:"agent"`
	ControlPlaneURL     string            `json:"control_plane_url"`
	AgentToken          string            `json:"agent_token"`
	AgentTokenFile      string            `json:"agent_token_file"`
	AllowInsecureRemote bool              `json:"allow_insecure_remote"`
	WorkspaceRoot       string            `json:"workspace_root"`
	SourceAliases       map[string]string `json:"source_aliases"`
	RequiredBins        []string          `json:"required_bins"`
}

func LoadRuntimeProfileConfig(path string) (RuntimeProfileConfig, error) {
	if path == "" {
		return RuntimeProfileConfig{}, nil
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return RuntimeProfileConfig{}, err
	}
	var config RuntimeProfileConfig
	if err := json.Unmarshal(content, &config); err != nil {
		return RuntimeProfileConfig{}, err
	}
	if config.SourceAliases == nil {
		config.SourceAliases = map[string]string{}
	}
	if err := config.Validate(); err != nil {
		return RuntimeProfileConfig{}, fmt.Errorf("invalid runtime profile %s: %w", path, err)
	}
	return config, nil
}

func (c RuntimeProfileConfig) Validate() error {
	if err := validateControlPlaneURL(c.ControlPlaneURL, c.AllowInsecureRemote); err != nil {
		return err
	}
	if c.WorkspaceRoot == "" && len(c.SourceAliases) > 0 {
		return fmt.Errorf("workspace_root is required when source_aliases are configured")
	}
	for alias, path := range c.SourceAliases {
		if alias == "" {
			return fmt.Errorf("source alias name must not be empty")
		}
		if path == "" {
			return fmt.Errorf("source alias %s path must not be empty", alias)
		}
	}
	return nil
}

func validateControlPlaneURL(rawURL string, allowInsecureRemote bool) error {
	if rawURL == "" {
		return nil
	}
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return fmt.Errorf("invalid control_plane_url: %w", err)
	}
	if parsed.Scheme != "http" {
		return nil
	}
	if allowInsecureRemote || isLocalHTTPHost(parsed.Hostname()) {
		return nil
	}
	return fmt.Errorf("control_plane_url uses remote HTTP; current A2O supports local topology only, use loopback/compose service URL or set allow_insecure_remote for an explicit diagnostic exception")
}

func isLocalHTTPHost(host string) bool {
	normalized := strings.ToLower(strings.TrimSpace(host))
	if normalized == "" || normalized == "localhost" {
		return true
	}
	ip := net.ParseIP(normalized)
	if ip != nil {
		return ip.IsLoopback()
	}
	return !strings.Contains(normalized, ".")
}
