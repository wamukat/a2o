package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type runtimeProjectRegistry struct {
	Version        int                                 `json:"version"`
	DefaultProject string                              `json:"default_project"`
	Projects       map[string]runtimeProjectDefinition `json:"projects"`
}

type runtimeProjectDefinition struct {
	PackagePath    string                       `json:"package_path"`
	WorkspaceRoot  string                       `json:"workspace_root,omitempty"`
	ComposeFile    string                       `json:"compose_file,omitempty"`
	ComposeProject string                       `json:"compose_project,omitempty"`
	RuntimeService string                       `json:"runtime_service,omitempty"`
	AgentPort      string                       `json:"agent_port,omitempty"`
	StorageDir     string                       `json:"storage_dir,omitempty"`
	RuntimeImage   string                       `json:"runtime_image,omitempty"`
	Kanban         runtimeProjectKanbanIdentity `json:"kanban"`
}

type runtimeProjectKanbanIdentity struct {
	Mode          string `json:"mode,omitempty"`
	URL           string `json:"url,omitempty"`
	RuntimeURL    string `json:"runtime_url,omitempty"`
	Port          string `json:"port,omitempty"`
	BoardID       int    `json:"board_id,omitempty"`
	Project       string `json:"project,omitempty"`
	TaskRefPrefix string `json:"task_ref_prefix,omitempty"`
}

type projectRuntimeContext struct {
	ProjectKey     string
	Definition     runtimeProjectDefinition
	KanbanIdentity runtimeProjectKanbanIdentity
	Config         runtimeInstanceConfig
}

func loadProjectRuntimeContextFromWorkingTree(projectKey string) (*projectRuntimeContext, string, error) {
	start, err := os.Getwd()
	if err != nil {
		return nil, "", fmt.Errorf("get working directory: %w", err)
	}
	registryPath, registryErr := findProjectRegistry(start)
	if registryErr == nil {
		context, err := readProjectRuntimeContext(registryPath, projectKey)
		return context, registryPath, err
	}
	if strings.TrimSpace(projectKey) != "" {
		return nil, "", fmt.Errorf("runtime project registry not found; --project requires %s", projectRegistryRelativePath)
	}
	config, configPath, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return nil, "", err
	}
	effectiveProjectKey := legacyProjectKey(*config)
	config.ProjectKey = effectiveProjectKey
	return &projectRuntimeContext{
		ProjectKey: effectiveProjectKey,
		Definition: runtimeProjectDefinition{
			PackagePath:    config.PackagePath,
			WorkspaceRoot:  config.WorkspaceRoot,
			ComposeFile:    config.ComposeFile,
			ComposeProject: config.ComposeProject,
			RuntimeService: config.RuntimeService,
			AgentPort:      config.AgentPort,
			StorageDir:     config.StorageDir,
			RuntimeImage:   config.RuntimeImage,
			Kanban: runtimeProjectKanbanIdentity{
				Mode:       config.KanbanMode,
				URL:        config.KanbanURL,
				RuntimeURL: config.KanbanRuntimeURL,
				Port:       config.KanbalonePort,
			},
		},
		KanbanIdentity: runtimeProjectKanbanIdentity{
			Mode:       config.KanbanMode,
			URL:        config.KanbanURL,
			RuntimeURL: config.KanbanRuntimeURL,
			Port:       config.KanbalonePort,
		},
		Config: *config,
	}, configPath, nil
}

func findProjectRegistry(start string) (string, error) {
	current, err := filepath.Abs(start)
	if err != nil {
		return "", err
	}
	for {
		candidate := filepath.Join(current, projectRegistryRelativePath)
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		}
		parent := filepath.Dir(current)
		if parent == current {
			return "", fmt.Errorf("A2O project registry not found")
		}
		current = parent
	}
}

func readProjectRuntimeContext(path string, projectKey string) (*projectRuntimeContext, error) {
	registry, err := readProjectRegistry(path)
	if err != nil {
		return nil, err
	}
	resolvedKey := strings.TrimSpace(projectKey)
	if resolvedKey == "" {
		resolvedKey = strings.TrimSpace(registry.DefaultProject)
	}
	if resolvedKey == "" {
		return nil, fmt.Errorf("project registry %s has no default_project; pass --project", path)
	}
	definition, ok := registry.Projects[resolvedKey]
	if !ok {
		return nil, fmt.Errorf("project %q not found in registry %s", resolvedKey, path)
	}
	config, err := runtimeInstanceConfigFromProjectDefinition(path, definition)
	if err != nil {
		return nil, err
	}
	config.ProjectKey = resolvedKey
	config.MultiProjectMode = true
	return &projectRuntimeContext{
		ProjectKey:     resolvedKey,
		Definition:     definition,
		KanbanIdentity: definition.Kanban,
		Config:         config,
	}, nil
}

func readProjectRegistry(path string) (*runtimeProjectRegistry, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read project registry: %w", err)
	}
	var registry runtimeProjectRegistry
	if err := json.Unmarshal(body, &registry); err != nil {
		return nil, fmt.Errorf("parse project registry %s: %w", path, err)
	}
	if registry.Version != 1 {
		return nil, fmt.Errorf("unsupported project registry version: %d", registry.Version)
	}
	if len(registry.Projects) == 0 {
		return nil, fmt.Errorf("project registry %s has no projects", path)
	}
	return &registry, nil
}

func runtimeInstanceConfigFromProjectDefinition(registryPath string, definition runtimeProjectDefinition) (runtimeInstanceConfig, error) {
	workspaceRoot := strings.TrimSpace(definition.WorkspaceRoot)
	if workspaceRoot == "" {
		workspaceRoot = projectRegistryWorkspaceRoot(registryPath)
	} else {
		workspaceRoot = resolveRegistryPath(registryPath, workspaceRoot)
	}
	packagePath := strings.TrimSpace(definition.PackagePath)
	if packagePath == "" {
		return runtimeInstanceConfig{}, fmt.Errorf("project definition package_path is required")
	}
	packagePath = resolveRegistryPath(registryPath, packagePath)
	return runtimeInstanceConfig{
		SchemaVersion:    1,
		PackagePath:      packagePath,
		WorkspaceRoot:    workspaceRoot,
		ComposeFile:      resolveRegistryPath(registryPath, definition.ComposeFile),
		ComposeProject:   strings.TrimSpace(definition.ComposeProject),
		RuntimeService:   strings.TrimSpace(definition.RuntimeService),
		KanbalonePort:    strings.TrimSpace(definition.Kanban.Port),
		KanbanMode:       strings.TrimSpace(definition.Kanban.Mode),
		KanbanURL:        strings.TrimSpace(definition.Kanban.URL),
		KanbanRuntimeURL: strings.TrimSpace(definition.Kanban.RuntimeURL),
		AgentPort:        strings.TrimSpace(definition.AgentPort),
		StorageDir:       strings.TrimSpace(definition.StorageDir),
		RuntimeImage:     strings.TrimSpace(definition.RuntimeImage),
	}, nil
}

func projectRegistryWorkspaceRoot(registryPath string) string {
	return filepath.Clean(filepath.Join(filepath.Dir(registryPath), "..", ".."))
}

func resolveRegistryPath(registryPath string, value string) string {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" || filepath.IsAbs(trimmed) {
		return trimmed
	}
	return filepath.Join(projectRegistryWorkspaceRoot(registryPath), trimmed)
}

func legacyProjectKey(config runtimeInstanceConfig) string {
	if value := strings.TrimSpace(config.ComposeProject); value != "" {
		return strings.TrimPrefix(value, "a2o-")
	}
	return "default"
}
