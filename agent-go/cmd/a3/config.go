package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
)

type runtimeInstanceConfig struct {
	SchemaVersion    int    `json:"schema_version"`
	PackagePath      string `json:"package_path"`
	WorkspaceRoot    string `json:"workspace_root"`
	ComposeFile      string `json:"compose_file"`
	ComposeProject   string `json:"compose_project"`
	RuntimeService   string `json:"runtime_service"`
	KanbalonePort    string `json:"kanbalone_port"`
	KanbanMode       string `json:"kanban_mode,omitempty"`
	KanbanURL        string `json:"kanban_url,omitempty"`
	KanbanRuntimeURL string `json:"kanban_runtime_url,omitempty"`
	AgentPort        string `json:"agent_port"`
	StorageDir       string `json:"storage_dir"`
	RuntimeImage     string `json:"runtime_image,omitempty"`
}

var internalGeneratedA3EnvDepth atomic.Int32

func defaultComposeFile() string {
	candidates := []string{}
	if executablePath, err := os.Executable(); err == nil {
		executableDir := filepath.Dir(executablePath)
		candidates = append(
			candidates,
			filepath.Join(executableDir, "..", "share", "a2o", "docker", "compose", "a2o-kanbalone.yml"),
			filepath.Join(executableDir, "..", "share", "a3", "docker", "compose", "a2o-kanbalone.yml"),
		)
	}
	candidates = append(candidates,
		"a3-engine/docker/compose/a2o-kanbalone.yml",
		"docker/compose/a2o-kanbalone.yml",
		"../docker/compose/a2o-kanbalone.yml",
		"../share/a2o/docker/compose/a2o-kanbalone.yml",
		"../share/a3/docker/compose/a2o-kanbalone.yml",
	)
	for _, candidate := range candidates {
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return candidates[0]
}

func defaultRuntimeImage() string {
	if value := explicitRuntimeImageReference(); value != "" {
		return value
	}
	return packagedRuntimeImageReferenceFunc()
}

func explicitRuntimeImageReference() string {
	if value := strings.TrimSpace(os.Getenv("A2O_RUNTIME_IMAGE")); value != "" {
		return value
	}
	return ""
}

func packagedRuntimeImageReference() string {
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

var packagedRuntimeImageReferenceFunc = packagedRuntimeImageReference

func runtimeImageReference(config *runtimeInstanceConfig) string {
	return selectRuntimeImageReference(config, explicitRuntimeImageReference(), packagedRuntimeImageReferenceFunc())
}

func selectRuntimeImageReference(config *runtimeInstanceConfig, explicitRef string, packagedRef string) string {
	if value := strings.TrimSpace(explicitRef); value != "" {
		return value
	}
	if config != nil {
		if value := strings.TrimSpace(config.RuntimeImage); value != "" {
			return value
		}
	}
	return strings.TrimSpace(packagedRef)
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

func publicInstanceConfigPath(configPath string) string {
	cleanPath := filepath.Clean(configPath)
	legacySuffix := filepath.FromSlash(legacyInstanceConfigRelativePath)
	if strings.HasSuffix(cleanPath, legacySuffix) {
		workspaceRoot := strings.TrimSuffix(cleanPath, legacySuffix)
		workspaceRoot = strings.TrimSuffix(workspaceRoot, string(filepath.Separator))
		return filepath.Join(workspaceRoot, filepath.FromSlash(instanceConfigRelativePath))
	}
	return configPath
}

func readInstanceConfig(path string) (*runtimeInstanceConfig, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read instance config: %w", err)
	}
	if strings.Contains(string(body), `"soloboard_port"`) {
		return nil, removedSoloBoardInputError("runtime instance config field soloboard_port", "kanbalone_port")
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
		config.ComposeProject = envDefault("A2O_COMPOSE_PROJECT", "a2o-runtime")
	}
	if strings.TrimSpace(config.ComposeFile) == "" {
		config.ComposeFile = envDefault("A2O_COMPOSE_FILE", defaultComposeFile())
	}
	if strings.TrimSpace(config.RuntimeService) == "" {
		config.RuntimeService = envDefault("A2O_RUNTIME_SERVICE", "a2o-runtime")
	}
	if envComposeProject := envDefault("A2O_COMPOSE_PROJECT", ""); envComposeProject != "" {
		config.ComposeProject = envComposeProject
	}
	if envComposeFile := envDefault("A2O_COMPOSE_FILE", ""); envComposeFile != "" {
		config.ComposeFile = envComposeFile
	}
	if envRuntimeService := envDefault("A2O_RUNTIME_SERVICE", ""); envRuntimeService != "" {
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
	if strings.TrimSpace(config.RuntimeService) == "a3-runtime" {
		config.RuntimeService = "a2o-runtime"
	}
	return config
}

func composeArgs(config runtimeInstanceConfig) []string {
	config = applyAgentInstallOverrides(config, "", "", "")
	return []string{"compose", "-p", config.ComposeProject, "-f", config.ComposeFile}
}

func runtimeServiceName(config runtimeInstanceConfig) string {
	return applyAgentInstallOverrides(config, "", "", "").RuntimeService
}

func withComposeEnv(config runtimeInstanceConfig, fn func() error) error {
	if err := validateRemovedSoloBoardEnvironment(); err != nil {
		return err
	}
	if err := validateRemovedA3Environment(); err != nil {
		return err
	}
	return withEnv(composeEnv(config), fn)
}

func composeEnv(config runtimeInstanceConfig) map[string]string {
	overrides := map[string]string{}
	if kanbanPort := strings.TrimSpace(os.Getenv("A2O_BUNDLE_KANBALONE_PORT")); kanbanPort != "" {
		overrides["A2O_BUNDLE_KANBALONE_PORT"] = kanbanPort
	} else if kanbanPort := strings.TrimSpace(config.KanbalonePort); kanbanPort != "" {
		overrides["A2O_BUNDLE_KANBALONE_PORT"] = kanbanPort
	}
	if agentPort := envDefault("A2O_BUNDLE_AGENT_PORT", config.AgentPort); strings.TrimSpace(agentPort) != "" {
		overrides["A2O_BUNDLE_AGENT_PORT"] = agentPort
	}
	if strings.TrimSpace(config.WorkspaceRoot) != "" {
		overrides["A2O_WORKSPACE_ROOT"] = config.WorkspaceRoot
		overrides["A2O_HOST_WORKSPACE_ROOT"] = config.WorkspaceRoot
	}
	if runtimeImage := runtimeImageReference(&config); runtimeImage != "" {
		overrides["A2O_RUNTIME_IMAGE"] = runtimeImage
	}
	if runtimeURL := kanbanRuntimeURL(config); isExternalKanban(config) && runtimeURL != "" {
		overrides["A2O_KANBALONE_INTERNAL_URL"] = runtimeURL
	}
	return overrides
}

func removedSoloBoardInputError(removed string, replacement string) error {
	return fmt.Errorf("removed SoloBoard compatibility input: %s; migration_required=true replacement=%s", removed, replacement)
}

func validateRemovedSoloBoardEnvironment() error {
	replacements := map[string]string{
		"A2O_BUNDLE_SOLOBOARD_PORT":  "A2O_BUNDLE_KANBALONE_PORT",
		"A3_BUNDLE_SOLOBOARD_PORT":   "A2O_BUNDLE_KANBALONE_PORT",
		"A2O_SOLOBOARD_INTERNAL_URL": "A2O_KANBALONE_INTERNAL_URL",
		"A3_SOLOBOARD_INTERNAL_URL":  "A2O_KANBALONE_INTERNAL_URL",
		"SOLOBOARD_BASE_URL":         "KANBALONE_BASE_URL",
		"SOLOBOARD_API_TOKEN":        "KANBALONE_API_TOKEN",
	}
	for removed, replacement := range replacements {
		if strings.TrimSpace(os.Getenv(removed)) != "" {
			return removedSoloBoardInputError("environment variable "+removed, "environment variable "+replacement)
		}
	}
	return nil
}

func removedA3InputError(removed string, replacement string) error {
	return fmt.Errorf("removed A3 compatibility input: %s; migration_required=true replacement=%s", removed, replacement)
}

func validateRemovedA3Environment() error {
	if internalGeneratedA3EnvDepth.Load() > 0 {
		return nil
	}
	for _, removed := range removedA3EnvironmentNames() {
		replacement := "A2O_" + strings.TrimPrefix(removed, "A3_")
		if strings.TrimSpace(os.Getenv(removed)) != "" {
			return removedA3InputError("environment variable "+removed, "environment variable "+replacement)
		}
	}
	return nil
}

func removedA3EnvironmentNames() []string {
	return []string{
		"A3_AGENT_AI_RAW_LOG_ROOT",
		"A3_AGENT_LIVE_LOG_ROOT",
		"A3_BUNDLE_AGENT_PORT",
		"A3_BUNDLE_COMPOSE_FILE",
		"A3_BUNDLE_PROJECT",
		"A3_BUNDLE_STORAGE_DIR",
		"A3_COMPOSE_FILE",
		"A3_COMPOSE_PROJECT",
		"A3_HOST_AGENT_BIN",
		"A3_HOST_WORKSPACE_ROOT",
		"A3_RUNTIME_IMAGE",
		"A3_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS",
		"A3_RUNTIME_RUN_ONCE_AGENT_CONTROL_PLANE_CONNECT_TIMEOUT",
		"A3_RUNTIME_RUN_ONCE_AGENT_CONTROL_PLANE_REQUEST_TIMEOUT",
		"A3_RUNTIME_RUN_ONCE_AGENT_CONTROL_PLANE_RETRIES",
		"A3_RUNTIME_RUN_ONCE_AGENT_CONTROL_PLANE_RETRY_DELAY",
		"A3_RUNTIME_RUN_ONCE_AGENT_INTERNAL_PORT",
		"A3_RUNTIME_RUN_ONCE_AGENT_JOB_TIMEOUT_SECONDS",
		"A3_RUNTIME_RUN_ONCE_AGENT_LOCAL_MATERIALIZER_ARGS",
		"A3_RUNTIME_RUN_ONCE_AGENT_POLL_INTERVAL",
		"A3_RUNTIME_RUN_ONCE_AGENT_REQUIRED_BINS",
		"A3_RUNTIME_RUN_ONCE_AGENT_SOURCE",
		"A3_RUNTIME_RUN_ONCE_AGENT_SOURCE_ALIASES",
		"A3_RUNTIME_RUN_ONCE_AGENT_SOURCE_PATHS",
		"A3_RUNTIME_RUN_ONCE_AGENT_TARGET",
		"A3_RUNTIME_RUN_ONCE_AGENT_WORKSPACE_ROOT",
		"A3_RUNTIME_RUN_ONCE_ARCHIVE_STATE",
		"A3_RUNTIME_RUN_ONCE_EXIT_FILE",
		"A3_RUNTIME_RUN_ONCE_HOST_AGENT_LOG",
		"A3_RUNTIME_RUN_ONCE_HOST_ROOT",
		"A3_RUNTIME_RUN_ONCE_HOST_ROOT_DIR",
		"A3_RUNTIME_RUN_ONCE_KANBAN_PROJECT",
		"A3_RUNTIME_RUN_ONCE_KANBAN_REPO_LABELS",
		"A3_RUNTIME_RUN_ONCE_KANBAN_STATUS",
		"A3_RUNTIME_RUN_ONCE_LIVE_REF",
		"A3_RUNTIME_RUN_ONCE_LOCAL_SOURCE_ALIASES",
		"A3_RUNTIME_RUN_ONCE_LOG",
		"A3_RUNTIME_RUN_ONCE_MAVEN_WORKSPACE_BOOTSTRAP_MODE",
		"A3_RUNTIME_RUN_ONCE_MAX_STEPS",
		"A3_RUNTIME_RUN_ONCE_PID_FILE",
		"A3_RUNTIME_RUN_ONCE_PRESET_DIR",
		"A3_RUNTIME_RUN_ONCE_PROJECT_CONFIG",
		"A3_RUNTIME_RUN_ONCE_REFERENCE_PACKAGE",
		"A3_RUNTIME_RUN_ONCE_REPO_SOURCES",
		"A3_RUNTIME_RUN_ONCE_SERVER_LOG",
		"A3_RUNTIME_RUN_ONCE_SERVER_PID_FILE",
		"A3_RUNTIME_RUN_ONCE_WORKER",
		"A3_RUNTIME_RUN_ONCE_WORKER_ARGS",
		"A3_RUNTIME_RUN_ONCE_WORKER_COMMAND",
		"A3_RUNTIME_SCHEDULER_AGENT_ATTEMPTS",
		"A3_RUNTIME_SCHEDULER_AGENT_CONTROL_PLANE_CONNECT_TIMEOUT",
		"A3_RUNTIME_SCHEDULER_AGENT_CONTROL_PLANE_REQUEST_TIMEOUT",
		"A3_RUNTIME_SCHEDULER_AGENT_CONTROL_PLANE_RETRIES",
		"A3_RUNTIME_SCHEDULER_AGENT_CONTROL_PLANE_RETRY_DELAY",
		"A3_RUNTIME_SCHEDULER_AGENT_INTERNAL_PORT",
		"A3_RUNTIME_SCHEDULER_AGENT_JOB_TIMEOUT_SECONDS",
		"A3_RUNTIME_SCHEDULER_AGENT_LOCAL_MATERIALIZER_ARGS",
		"A3_RUNTIME_SCHEDULER_AGENT_POLL_INTERVAL",
		"A3_RUNTIME_SCHEDULER_AGENT_REQUIRED_BINS",
		"A3_RUNTIME_SCHEDULER_AGENT_SOURCE",
		"A3_RUNTIME_SCHEDULER_AGENT_SOURCE_ALIASES",
		"A3_RUNTIME_SCHEDULER_AGENT_SOURCE_PATHS",
		"A3_RUNTIME_SCHEDULER_AGENT_TARGET",
		"A3_RUNTIME_SCHEDULER_AGENT_WORKSPACE_ROOT",
		"A3_RUNTIME_SCHEDULER_ARCHIVE_STATE",
		"A3_RUNTIME_SCHEDULER_EXIT_FILE",
		"A3_RUNTIME_SCHEDULER_HOST_AGENT_LOG",
		"A3_RUNTIME_SCHEDULER_HOST_ROOT",
		"A3_RUNTIME_SCHEDULER_HOST_ROOT_DIR",
		"A3_RUNTIME_SCHEDULER_KANBAN_PROJECT",
		"A3_RUNTIME_SCHEDULER_KANBAN_REPO_LABELS",
		"A3_RUNTIME_SCHEDULER_KANBAN_STATUS",
		"A3_RUNTIME_SCHEDULER_LIVE_REF",
		"A3_RUNTIME_SCHEDULER_LOCAL_SOURCE_ALIASES",
		"A3_RUNTIME_SCHEDULER_LOG",
		"A3_RUNTIME_SCHEDULER_MAVEN_WORKSPACE_BOOTSTRAP_MODE",
		"A3_RUNTIME_SCHEDULER_MAX_STEPS",
		"A3_RUNTIME_SCHEDULER_PID_FILE",
		"A3_RUNTIME_SCHEDULER_PRESET_DIR",
		"A3_RUNTIME_SCHEDULER_PROJECT_CONFIG",
		"A3_RUNTIME_SCHEDULER_REFERENCE_PACKAGE",
		"A3_RUNTIME_SCHEDULER_REPO_SOURCES",
		"A3_RUNTIME_SCHEDULER_SERVER_LOG",
		"A3_RUNTIME_SCHEDULER_SERVER_PID_FILE",
		"A3_RUNTIME_SCHEDULER_WORKER",
		"A3_RUNTIME_SCHEDULER_WORKER_ARGS",
		"A3_RUNTIME_SCHEDULER_WORKER_COMMAND",
		"A3_RUNTIME_SERVICE",
		"A3_WORKER_LAUNCHER_CONFIG_PATH",
		"A3_WORKSPACE_ROOT",
	}
}

func runtimeRunOnceEnv(config runtimeInstanceConfig, maxSteps string, agentAttempts string) map[string]string {
	overrides := composeEnv(config)
	overrides["A2O_BUNDLE_COMPOSE_FILE"] = config.ComposeFile
	overrides["A2O_BUNDLE_PROJECT"] = config.ComposeProject
	if storageDir := envDefault("A2O_BUNDLE_STORAGE_DIR", config.StorageDir); strings.TrimSpace(storageDir) != "" {
		overrides["A2O_BUNDLE_STORAGE_DIR"] = storageDir
	}
	if strings.TrimSpace(config.WorkspaceRoot) != "" {
		overrides["A2O_RUNTIME_RUN_ONCE_HOST_ROOT_DIR"] = config.WorkspaceRoot
		overrides["A2O_RUNTIME_RUN_ONCE_HOST_ROOT"] = filepath.Join(config.WorkspaceRoot, runtimeHostAgentRelativePath)
		overrides["A2O_HOST_AGENT_BIN"] = filepath.Join(config.WorkspaceRoot, hostAgentBinRelativePath)
	}
	if strings.TrimSpace(config.ComposeProject) != "" {
		overrides["A2O_BRANCH_NAMESPACE"] = defaultBranchNamespace(config.ComposeProject)
	}
	if strings.TrimSpace(maxSteps) != "" {
		overrides["A2O_RUNTIME_RUN_ONCE_MAX_STEPS"] = strings.TrimSpace(maxSteps)
	}
	if strings.TrimSpace(agentAttempts) != "" {
		overrides["A2O_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS"] = strings.TrimSpace(agentAttempts)
	}
	return overrides
}

func withRuntimeRunOnceEnv(config runtimeInstanceConfig, maxSteps string, agentAttempts string, fn func() error) error {
	if err := validateRemovedA3Environment(); err != nil {
		return err
	}
	internalGeneratedA3EnvDepth.Add(1)
	defer internalGeneratedA3EnvDepth.Add(-1)
	return withEnv(runtimeRunOnceEnv(config, maxSteps, agentAttempts), fn)
}
