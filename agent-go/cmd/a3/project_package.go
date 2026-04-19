package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

type projectPackageConfig struct {
	SchemaVersion      string
	PackageName        string
	KanbanProject      string
	KanbanBootstrap    string
	KanbanStatus       string
	LiveRef            string
	MaxSteps           string
	AgentAttempts      string
	AgentWorkspaceRoot string
	AgentRequiredBins  []string
	Executor           map[string]any
	Repos              map[string]projectPackageRepo
}

type projectPackageRepo struct {
	Path  string
	Label string
}

func loadProjectPackageConfig(packagePath string) (projectPackageConfig, error) {
	config := projectPackageConfig{Repos: map[string]projectPackageRepo{}}
	projectFile := filepath.Join(packagePath, "project.yaml")
	legacyManifest := filepath.Join(packagePath, "manifest.yml")
	if _, err := os.Stat(legacyManifest); err == nil {
		return config, fmt.Errorf("manifest.yml is no longer supported; move runtime config into project.yaml: %s", legacyManifest)
	} else if err != nil && !os.IsNotExist(err) {
		return config, fmt.Errorf("inspect legacy manifest: %w", err)
	}
	body, err := os.ReadFile(projectFile)
	if err != nil {
		if os.IsNotExist(err) {
			return config, fmt.Errorf("project package config not found: %s", projectFile)
		}
		return config, fmt.Errorf("read project package config: %w", err)
	}
	var payload projectPackageYAML
	if err := yaml.Unmarshal(body, &payload); err != nil {
		return config, fmt.Errorf("parse project package config %s: %w", projectFile, err)
	}
	config.SchemaVersion = scalarString(payload.SchemaVersion)
	config.PackageName = payload.Package.Name
	config.KanbanProject = payload.Kanban.Project
	config.KanbanBootstrap = payload.Kanban.Bootstrap
	config.KanbanStatus = payload.Kanban.Selection.Status
	config.LiveRef = scalarString(payload.Runtime.LiveRef)
	config.MaxSteps = scalarString(payload.Runtime.MaxSteps)
	config.AgentAttempts = scalarString(payload.Runtime.AgentAttempts)
	config.AgentWorkspaceRoot = payload.Agent.WorkspaceRoot
	config.AgentRequiredBins = payload.Agent.RequiredBins
	authorExecutor := normalizeYAMLValue(payload.Runtime.Executor)
	if len(authorExecutor) > 0 {
		if err := validateProjectAuthorExecutorConfig(authorExecutor); err != nil {
			return config, fmt.Errorf("project package config %s has invalid runtime.executor: %w", projectFile, err)
		}
	}
	config.Executor = expandProjectExecutorConfig(authorExecutor)
	for alias, repo := range payload.Repos {
		config.Repos[alias] = projectPackageRepo{Path: repo.Path, Label: repo.Label}
	}
	if strings.TrimSpace(config.SchemaVersion) == "" {
		return config, fmt.Errorf("project package config %s is missing schema_version", projectFile)
	}
	if config.SchemaVersion != "1" {
		return config, fmt.Errorf("project package config %s has unsupported schema_version: %s", projectFile, config.SchemaVersion)
	}
	if strings.TrimSpace(config.PackageName) == "" {
		return config, fmt.Errorf("project package config %s is missing package.name", projectFile)
	}
	if strings.TrimSpace(config.KanbanProject) == "" {
		return config, fmt.Errorf("project package config %s is missing kanban.project", projectFile)
	}
	if len(config.Repos) == 0 {
		return config, fmt.Errorf("project package config %s is missing repos", projectFile)
	}
	return config, nil
}

func expandProjectExecutorConfig(executor map[string]any) map[string]any {
	if len(executor) == 0 {
		return executor
	}
	command, hasCommand := executor["command"]
	if !hasCommand {
		return executor
	}
	expanded := map[string]any{
		"kind":             "command",
		"prompt_transport": "stdin-bundle",
		"result":           map[string]any{"mode": "file"},
		"schema":           map[string]any{"mode": "file"},
		"default_profile": map[string]any{
			"command": command,
		},
		"phase_profiles": map[string]any{},
	}
	if env, ok := executor["env"]; ok {
		expanded["default_profile"].(map[string]any)["env"] = env
	} else {
		expanded["default_profile"].(map[string]any)["env"] = map[string]any{}
	}
	if phaseProfiles, ok := executor["phase_profiles"]; ok {
		expanded["phase_profiles"] = phaseProfiles
	}
	return expanded
}

type projectPackageYAML struct {
	SchemaVersion any `yaml:"schema_version"`
	Package       struct {
		Name string `yaml:"name"`
	} `yaml:"package"`
	Kanban struct {
		Project   string `yaml:"project"`
		Bootstrap string `yaml:"bootstrap"`
		Selection struct {
			Status string `yaml:"status"`
		} `yaml:"selection"`
	} `yaml:"kanban"`
	Repos map[string]struct {
		Path  string `yaml:"path"`
		Label string `yaml:"label"`
	} `yaml:"repos"`
	Agent struct {
		WorkspaceRoot string   `yaml:"workspace_root"`
		RequiredBins  []string `yaml:"required_bins"`
	} `yaml:"agent"`
	Runtime struct {
		LiveRef       any            `yaml:"live_ref"`
		MaxSteps      any            `yaml:"max_steps"`
		AgentAttempts any            `yaml:"agent_attempts"`
		Executor      map[string]any `yaml:"executor"`
	} `yaml:"runtime"`
}

func scalarString(value any) string {
	switch typed := value.(type) {
	case nil:
		return ""
	case string:
		return typed
	case int:
		return fmt.Sprintf("%d", typed)
	case int64:
		return fmt.Sprintf("%d", typed)
	case uint64:
		return fmt.Sprintf("%d", typed)
	case float64:
		return fmt.Sprintf("%.0f", typed)
	case bool:
		if typed {
			return "true"
		}
		return "false"
	default:
		return fmt.Sprintf("%v", typed)
	}
}

func normalizeYAMLValue[T any](value T) T {
	body, err := json.Marshal(value)
	if err != nil {
		return value
	}
	var normalized T
	if err := json.Unmarshal(body, &normalized); err != nil {
		return value
	}
	return normalized
}

func validateProjectAuthorExecutorConfig(executor map[string]any) error {
	if err := rejectInternalProjectExecutorKeys(executor, "executor"); err != nil {
		return err
	}
	if err := validateProjectExecutorProfile(executor, "executor"); err != nil {
		return err
	}
	phaseProfiles := map[string]any{}
	if raw, ok := executor["phase_profiles"].(map[string]any); ok {
		phaseProfiles = raw
	} else if executor["phase_profiles"] != nil {
		return fmt.Errorf("phase_profiles must be an object")
	}
	for phase, rawProfile := range phaseProfiles {
		if !containsString([]string{"implementation", "review", "parent_review"}, phase) {
			return fmt.Errorf("phase_profiles contains unknown phase: %s", phase)
		}
		label := "phase_profiles." + phase
		profile, ok := rawProfile.(map[string]any)
		if !ok {
			return fmt.Errorf("%s must be an object", label)
		}
		if err := rejectInternalProjectExecutorKeys(profile, label); err != nil {
			return err
		}
		if err := validateProjectExecutorProfile(profile, label); err != nil {
			return err
		}
	}
	return nil
}

func rejectInternalProjectExecutorKeys(executor map[string]any, label string) error {
	for _, key := range []string{"kind", "prompt_transport", "result", "schema", "default_profile"} {
		if _, ok := executor[key]; ok {
			return fmt.Errorf("%s.%s is internal; use runtime.executor.command in project.yaml", label, key)
		}
	}
	return nil
}

func validateProjectExecutorProfile(raw any, label string) error {
	profile, ok := raw.(map[string]any)
	if !ok {
		return fmt.Errorf("%s must be an object", label)
	}
	command, ok := profile["command"].([]any)
	if !ok || len(command) == 0 {
		return fmt.Errorf("%s.command must be a non-empty array of non-empty strings", label)
	}
	for _, entry := range command {
		if projectConfigString(entry) == "" {
			return fmt.Errorf("%s.command must be a non-empty array of non-empty strings", label)
		}
	}
	if err := validateProjectStringMap(profile["env"], label+".env"); err != nil {
		return err
	}
	return nil
}

func projectConfigString(value any) string {
	text, _ := value.(string)
	return text
}

func validateProjectStringMap(raw any, label string) error {
	if raw == nil {
		return nil
	}
	values, ok := raw.(map[string]any)
	if !ok {
		return fmt.Errorf("%s must be an object", label)
	}
	for key, value := range values {
		if key == "" {
			return fmt.Errorf("%s keys must be non-empty strings", label)
		}
		if _, ok := value.(string); !ok {
			return fmt.Errorf("%s.%s must be a string", label, key)
		}
	}
	return nil
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func sortedProjectRepoAliases(repos map[string]projectPackageRepo) []string {
	aliases := make([]string, 0, len(repos))
	for alias := range repos {
		aliases = append(aliases, alias)
	}
	sort.Strings(aliases)
	return aliases
}

func resolvePackagePath(packagePath string, relativePath string) string {
	if filepath.IsAbs(relativePath) {
		return filepath.Clean(relativePath)
	}
	return filepath.Clean(filepath.Join(packagePath, relativePath))
}

func workspaceContainerPath(hostWorkspaceRoot string, hostPath string) string {
	relative, err := filepath.Rel(hostWorkspaceRoot, hostPath)
	if err != nil || strings.HasPrefix(relative, "..") {
		return filepath.ToSlash(hostPath)
	}
	if relative == "." {
		return "/workspace"
	}
	return "/workspace/" + filepath.ToSlash(relative)
}
