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
				Project:    config.KanbanProject,
			},
		},
		KanbanIdentity: runtimeProjectKanbanIdentity{
			Mode:       config.KanbanMode,
			URL:        config.KanbanURL,
			RuntimeURL: config.KanbanRuntimeURL,
			Port:       config.KanbalonePort,
			Project:    config.KanbanProject,
		},
		Config: *config,
	}, configPath, nil
}

func loadProjectRuntimeContextForCommand(projectKey string, requireExplicitForMultiple bool) (*projectRuntimeContext, string, error) {
	start, err := os.Getwd()
	if err != nil {
		return nil, "", fmt.Errorf("get working directory: %w", err)
	}
	registryPath, registryErr := findProjectRegistry(start)
	if registryErr != nil {
		if strings.TrimSpace(projectKey) != "" {
			return nil, "", fmt.Errorf("runtime project registry not found; --project requires %s", projectRegistryRelativePath)
		}
		return loadProjectRuntimeContextFromWorkingTree("")
	}
	registry, err := readProjectRegistry(registryPath)
	if err != nil {
		return nil, "", err
	}
	if requireExplicitForMultiple && len(registry.Projects) > 1 && strings.TrimSpace(projectKey) == "" {
		return nil, "", fmt.Errorf("multi-project runtime command requires --project when %s defines multiple projects", projectRegistryRelativePath)
	}
	context, err := projectRuntimeContextFromRegistry(registryPath, registry, projectKey)
	return context, registryPath, err
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
	return projectRuntimeContextFromRegistry(path, registry, projectKey)
}

func projectRuntimeContextFromRegistry(path string, registry *runtimeProjectRegistry, projectKey string) (*projectRuntimeContext, error) {
	resolvedKey := strings.TrimSpace(projectKey)
	if resolvedKey == "" {
		resolvedKey = strings.TrimSpace(envDefault("A2O_PROJECT_KEY", registry.DefaultProject))
	}
	if resolvedKey == "" {
		return nil, fmt.Errorf("project registry %s has no default_project; pass --project", path)
	}
	definition, ok := registry.Projects[resolvedKey]
	if !ok {
		return nil, fmt.Errorf("project %q not found in registry %s", resolvedKey, path)
	}
	config, err := runtimeInstanceConfigFromProjectDefinition(path, resolvedKey, definition)
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

func resolveRuntimeProjectTaskRef(projectKey string, taskRef string) (string, string, error) {
	qualifiedProject, bareTaskRef, ok := splitRuntimeQualifiedTaskRef(taskRef)
	if !ok {
		return strings.TrimSpace(projectKey), strings.TrimSpace(taskRef), nil
	}
	if strings.TrimSpace(projectKey) != "" && strings.TrimSpace(projectKey) != qualifiedProject {
		return "", "", fmt.Errorf("task ref project %q conflicts with --project %q", qualifiedProject, strings.TrimSpace(projectKey))
	}
	return qualifiedProject, bareTaskRef, nil
}

func splitRuntimeQualifiedTaskRef(taskRef string) (string, string, bool) {
	trimmed := strings.TrimSpace(taskRef)
	index := strings.Index(trimmed, ":")
	if index <= 0 || index == len(trimmed)-1 {
		return "", trimmed, false
	}
	qualifiedProject := strings.TrimSpace(trimmed[:index])
	bareTaskRef := strings.TrimSpace(trimmed[index+1:])
	if qualifiedProject == "" || bareTaskRef == "" || !strings.Contains(bareTaskRef, "#") {
		return "", trimmed, false
	}
	return qualifiedProject, bareTaskRef, true
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
	if err := validateProjectRegistry(path, registry); err != nil {
		return nil, err
	}
	return &registry, nil
}

func validateProjectRegistry(path string, registry runtimeProjectRegistry) error {
	storageOwners := map[string]string{}
	for key, definition := range registry.Projects {
		projectKey := strings.TrimSpace(key)
		if projectKey == "" {
			return fmt.Errorf("project registry %s has an empty project key", path)
		}
		if safeRuntimeLogComponent(projectKey) != projectKey {
			return fmt.Errorf("project registry %s has unsafe project key %q; use ASCII letters, numbers, '.', '_', '-', or ':'", path, key)
		}
		storageDir := projectStorageDir(projectKey, definition.StorageDir)
		if owner, exists := storageOwners[storageDir]; exists {
			return fmt.Errorf("project registry %s maps projects %q and %q to the same storage_dir %q", path, owner, projectKey, storageDir)
		}
		storageOwners[storageDir] = projectKey
	}
	return nil
}

func runtimeInstanceConfigFromProjectDefinition(registryPath string, projectKey string, definition runtimeProjectDefinition) (runtimeInstanceConfig, error) {
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
		KanbanProject:    strings.TrimSpace(definition.Kanban.Project),
		AgentPort:        strings.TrimSpace(definition.AgentPort),
		StorageDir:       projectStorageDir(projectKey, definition.StorageDir),
		RuntimeImage:     strings.TrimSpace(definition.RuntimeImage),
	}, nil
}

func projectStorageDir(projectKey string, configured string) string {
	if value := strings.TrimSpace(configured); value != "" {
		return filepath.Clean(value)
	}
	safeKey := safeRuntimeLogComponent(strings.TrimSpace(projectKey))
	if safeKey == "" {
		safeKey = "default"
	}
	return filepath.Join("/var/lib/a2o/projects", safeKey)
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
