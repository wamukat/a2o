package agent

import (
	"encoding/json"
	"fmt"
	"os"
)

type RuntimeProfileConfig struct {
	AgentName       string            `json:"agent"`
	ControlPlaneURL string            `json:"control_plane_url"`
	AgentToken      string            `json:"agent_token"`
	WorkspaceRoot   string            `json:"workspace_root"`
	SourceAliases   map[string]string `json:"source_aliases"`
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
