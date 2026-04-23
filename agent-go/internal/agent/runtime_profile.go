package agent

import (
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"strings"
	"time"
)

type RuntimeProfileConfig struct {
	AgentName                  string            `json:"agent"`
	ControlPlaneURL            string            `json:"control_plane_url"`
	AgentToken                 string            `json:"agent_token"`
	AgentTokenFile             string            `json:"agent_token_file"`
	ControlPlaneConnectTimeout string            `json:"control_plane_connect_timeout"`
	ControlPlaneRequestTimeout string            `json:"control_plane_request_timeout"`
	ControlPlaneRetryCount     int               `json:"control_plane_retry_count"`
	ControlPlaneRetryDelay     string            `json:"control_plane_retry_delay"`
	AllowInsecureRemote        bool              `json:"allow_insecure_remote"`
	WorkspaceRoot              string            `json:"workspace_root"`
	SourceAliases              map[string]string `json:"source_aliases"`
	RequiredBins               []string          `json:"required_bins"`
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
	if _, err := c.ControlPlaneConnectTimeoutDuration(); err != nil {
		return err
	}
	if _, err := c.ControlPlaneRequestTimeoutDuration(); err != nil {
		return err
	}
	if c.ControlPlaneRetryCount < 0 {
		return fmt.Errorf("control_plane_retry_count must be >= 0")
	}
	if _, err := c.ControlPlaneRetryDelayDuration(); err != nil {
		return err
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

func (c RuntimeProfileConfig) ControlPlaneConnectTimeoutDuration() (time.Duration, error) {
	return parseOptionalPositiveDuration(c.ControlPlaneConnectTimeout, "control_plane_connect_timeout")
}

func (c RuntimeProfileConfig) ControlPlaneRequestTimeoutDuration() (time.Duration, error) {
	return parseOptionalPositiveDuration(c.ControlPlaneRequestTimeout, "control_plane_request_timeout")
}

func (c RuntimeProfileConfig) ControlPlaneRetryDelayDuration() (time.Duration, error) {
	return parseOptionalNonNegativeDuration(c.ControlPlaneRetryDelay, "control_plane_retry_delay")
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

func parseOptionalPositiveDuration(raw string, label string) (time.Duration, error) {
	if strings.TrimSpace(raw) == "" {
		return 0, nil
	}
	value, err := time.ParseDuration(strings.TrimSpace(raw))
	if err != nil {
		return 0, fmt.Errorf("%s: %w", label, err)
	}
	if value <= 0 {
		return 0, fmt.Errorf("%s must be > 0", label)
	}
	return value, nil
}

func parseOptionalNonNegativeDuration(raw string, label string) (time.Duration, error) {
	if strings.TrimSpace(raw) == "" {
		return 0, nil
	}
	value, err := time.ParseDuration(strings.TrimSpace(raw))
	if err != nil {
		return 0, fmt.Errorf("%s: %w", label, err)
	}
	if value < 0 {
		return 0, fmt.Errorf("%s must be >= 0", label)
	}
	return value, nil
}
