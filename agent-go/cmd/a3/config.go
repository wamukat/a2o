package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type runtimeInstanceConfig struct {
	SchemaVersion  int    `json:"schema_version"`
	PackagePath    string `json:"package_path"`
	WorkspaceRoot  string `json:"workspace_root"`
	ComposeFile    string `json:"compose_file"`
	ComposeProject string `json:"compose_project"`
	RuntimeService string `json:"runtime_service"`
	SoloBoardPort  string `json:"soloboard_port"`
	AgentPort      string `json:"agent_port"`
	StorageDir     string `json:"storage_dir"`
}

func defaultComposeFile() string {
	candidates := []string{}
	if executablePath, err := os.Executable(); err == nil {
		executableDir := filepath.Dir(executablePath)
		candidates = append(
			candidates,
			filepath.Join(executableDir, "..", "share", "a2o", "docker", "compose", "a2o-soloboard.yml"),
			filepath.Join(executableDir, "..", "share", "a3", "docker", "compose", "a2o-soloboard.yml"),
		)
	}
	candidates = append(candidates,
		"a3-engine/docker/compose/a2o-soloboard.yml",
		"docker/compose/a2o-soloboard.yml",
		"../docker/compose/a2o-soloboard.yml",
		"../share/a2o/docker/compose/a2o-soloboard.yml",
		"../share/a3/docker/compose/a2o-soloboard.yml",
	)
	for _, candidate := range candidates {
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return candidates[0]
}

func defaultRuntimeImage() string {
	if value := strings.TrimSpace(os.Getenv("A2O_RUNTIME_IMAGE")); value != "" {
		return value
	}
	if value := strings.TrimSpace(os.Getenv("A3_RUNTIME_IMAGE")); value != "" {
		return value
	}
	if executablePath, err := os.Executable(); err == nil {
		for _, shareName := range []string{"a2o", "a3"} {
			path := filepath.Join(filepath.Dir(executablePath), "..", "share", shareName, "runtime-image")
			if body, err := os.ReadFile(path); err == nil {
				return strings.TrimSpace(string(body))
			}
		}
	}
	return ""
}

func writeInstanceConfig(workspaceRoot string, config runtimeInstanceConfig) error {
	path := filepath.Join(workspaceRoot, instanceConfigRelativePath)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create instance config directory: %w", err)
	}
	body, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return fmt.Errorf("encode instance config: %w", err)
	}
	body = append(body, '\n')
	if err := os.WriteFile(path, body, 0o644); err != nil {
		return fmt.Errorf("write instance config: %w", err)
	}
	return nil
}

func loadInstanceConfigFromWorkingTree() (*runtimeInstanceConfig, string, error) {
	start, err := os.Getwd()
	if err != nil {
		return nil, "", fmt.Errorf("get working directory: %w", err)
	}
	configPath, err := findInstanceConfig(start)
	if err != nil {
		return nil, "", err
	}
	config, err := readInstanceConfig(configPath)
	if err != nil {
		return nil, "", err
	}
	return config, configPath, nil
}

func findInstanceConfig(start string) (string, error) {
	current, err := filepath.Abs(start)
	if err != nil {
		return "", err
	}
	for {
		for _, relativePath := range []string{instanceConfigRelativePath, legacyInstanceConfigRelativePath} {
			candidate := filepath.Join(current, relativePath)
			if _, err := os.Stat(candidate); err == nil {
				return candidate, nil
			}
		}
		parent := filepath.Dir(current)
		if parent == current {
			return "", fmt.Errorf("A2O runtime instance config not found; run `a2o project bootstrap` from a workspace with ./a2o-project or ./project-package first")
		}
		current = parent
	}
}

func readInstanceConfig(path string) (*runtimeInstanceConfig, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read instance config: %w", err)
	}
	var config runtimeInstanceConfig
	if err := json.Unmarshal(body, &config); err != nil {
		return nil, fmt.Errorf("parse instance config %s: %w", path, err)
	}
	if config.SchemaVersion != 1 {
		return nil, fmt.Errorf("unsupported instance config schema_version: %d", config.SchemaVersion)
	}
	return &config, nil
}

func defaultComposeProjectName(packagePath string) string {
	base := filepath.Base(packagePath)
	slug := make([]rune, 0, len(base))
	lastDash := false
	for _, r := range strings.ToLower(base) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			slug = append(slug, r)
			lastDash = false
			continue
		}
		if !lastDash {
			slug = append(slug, '-')
			lastDash = true
		}
	}
	normalized := strings.Trim(string(slug), "-")
	if normalized == "" {
		normalized = "project"
	}
	normalized = strings.TrimPrefix(normalized, "a3-")
	if normalized == "" {
		normalized = "project"
	}
	return "a2o-" + normalized
}

func applyAgentInstallOverrides(config runtimeInstanceConfig, composeProject string, composeFile string, runtimeService string) runtimeInstanceConfig {
	if strings.TrimSpace(config.ComposeProject) == "" {
		config.ComposeProject = envDefaultCompat("A2O_COMPOSE_PROJECT", "A3_COMPOSE_PROJECT", "a2o-runtime")
	}
	if strings.TrimSpace(config.ComposeFile) == "" {
		config.ComposeFile = envDefaultCompat("A2O_COMPOSE_FILE", "A3_COMPOSE_FILE", defaultComposeFile())
	}
	if strings.TrimSpace(config.RuntimeService) == "" {
		config.RuntimeService = envDefaultCompat("A2O_RUNTIME_SERVICE", "A3_RUNTIME_SERVICE", "a2o-runtime")
	}
	if envComposeProject := envDefaultCompat("A2O_COMPOSE_PROJECT", "A3_COMPOSE_PROJECT", ""); envComposeProject != "" {
		config.ComposeProject = envComposeProject
	}
	if envComposeFile := envDefaultCompat("A2O_COMPOSE_FILE", "A3_COMPOSE_FILE", ""); envComposeFile != "" {
		config.ComposeFile = envComposeFile
	}
	if envRuntimeService := envDefaultCompat("A2O_RUNTIME_SERVICE", "A3_RUNTIME_SERVICE", ""); envRuntimeService != "" {
		config.RuntimeService = envRuntimeService
	}
	if strings.TrimSpace(composeProject) != "" {
		config.ComposeProject = strings.TrimSpace(composeProject)
	}
	if strings.TrimSpace(composeFile) != "" {
		config.ComposeFile = strings.TrimSpace(composeFile)
	}
	if strings.TrimSpace(runtimeService) != "" {
		config.RuntimeService = strings.TrimSpace(runtimeService)
	}
	return config
}

func composeArgs(config runtimeInstanceConfig) []string {
	config = applyAgentInstallOverrides(config, "", "", "")
	return []string{"compose", "-p", config.ComposeProject, "-f", config.ComposeFile}
}

func withComposeEnv(config runtimeInstanceConfig, fn func() error) error {
	return withEnv(composeEnv(config), fn)
}

func composeEnv(config runtimeInstanceConfig) map[string]string {
	overrides := map[string]string{}
	if soloboardPort := envDefaultCompat("A2O_BUNDLE_SOLOBOARD_PORT", "A3_BUNDLE_SOLOBOARD_PORT", config.SoloBoardPort); strings.TrimSpace(soloboardPort) != "" {
		overrides["A2O_BUNDLE_SOLOBOARD_PORT"] = soloboardPort
		overrides["A3_BUNDLE_SOLOBOARD_PORT"] = soloboardPort
	}
	if agentPort := envDefaultCompat("A2O_BUNDLE_AGENT_PORT", "A3_BUNDLE_AGENT_PORT", config.AgentPort); strings.TrimSpace(agentPort) != "" {
		overrides["A2O_BUNDLE_AGENT_PORT"] = agentPort
		overrides["A3_BUNDLE_AGENT_PORT"] = agentPort
	}
	if strings.TrimSpace(config.WorkspaceRoot) != "" {
		overrides["A2O_WORKSPACE_ROOT"] = config.WorkspaceRoot
		overrides["A2O_HOST_WORKSPACE_ROOT"] = config.WorkspaceRoot
		overrides["A3_WORKSPACE_ROOT"] = config.WorkspaceRoot
		overrides["A3_HOST_WORKSPACE_ROOT"] = config.WorkspaceRoot
	}
	if runtimeImage := defaultRuntimeImage(); runtimeImage != "" {
		overrides["A2O_RUNTIME_IMAGE"] = runtimeImage
		overrides["A3_RUNTIME_IMAGE"] = runtimeImage
	}
	return overrides
}

func runtimeRunOnceEnv(config runtimeInstanceConfig, maxSteps string, agentAttempts string) map[string]string {
	overrides := composeEnv(config)
	overrides["A2O_BUNDLE_COMPOSE_FILE"] = config.ComposeFile
	overrides["A2O_BUNDLE_PROJECT"] = config.ComposeProject
	overrides["A3_BUNDLE_COMPOSE_FILE"] = config.ComposeFile
	overrides["A3_BUNDLE_PROJECT"] = config.ComposeProject
	if storageDir := envDefaultCompat("A2O_BUNDLE_STORAGE_DIR", "A3_BUNDLE_STORAGE_DIR", config.StorageDir); strings.TrimSpace(storageDir) != "" {
		overrides["A2O_BUNDLE_STORAGE_DIR"] = storageDir
		overrides["A3_BUNDLE_STORAGE_DIR"] = storageDir
	}
	if strings.TrimSpace(config.WorkspaceRoot) != "" {
		overrides["A2O_RUNTIME_RUN_ONCE_HOST_ROOT_DIR"] = config.WorkspaceRoot
		overrides["A2O_RUNTIME_RUN_ONCE_HOST_ROOT"] = filepath.Join(config.WorkspaceRoot, runtimeHostAgentRelativePath)
		overrides["A2O_HOST_AGENT_BIN"] = filepath.Join(config.WorkspaceRoot, hostAgentBinRelativePath)
		overrides["A3_RUNTIME_RUN_ONCE_HOST_ROOT_DIR"] = config.WorkspaceRoot
		overrides["A3_RUNTIME_RUN_ONCE_HOST_ROOT"] = filepath.Join(config.WorkspaceRoot, runtimeHostAgentRelativePath)
		overrides["A3_HOST_AGENT_BIN"] = filepath.Join(config.WorkspaceRoot, hostAgentBinRelativePath)
	}
	if strings.TrimSpace(config.ComposeProject) != "" {
		overrides["A2O_BRANCH_NAMESPACE"] = defaultBranchNamespace(config.ComposeProject)
	}
	if strings.TrimSpace(maxSteps) != "" {
		overrides["A2O_RUNTIME_RUN_ONCE_MAX_STEPS"] = strings.TrimSpace(maxSteps)
		overrides["A3_RUNTIME_RUN_ONCE_MAX_STEPS"] = strings.TrimSpace(maxSteps)
	}
	if strings.TrimSpace(agentAttempts) != "" {
		overrides["A2O_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS"] = strings.TrimSpace(agentAttempts)
		overrides["A3_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS"] = strings.TrimSpace(agentAttempts)
	}
	return overrides
}
