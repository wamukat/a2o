package main

import (
	"encoding/json"
	"fmt"
	"github.com/wamukat/a3-engine/agent-go/internal/publishpolicy"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

type projectPackageConfig struct {
	SchemaVersion                   string
	PackageName                     string
	KanbanProject                   string
	KanbanLabels                    []string
	KanbanStatus                    string
	LiveRef                         string
	MaxSteps                        string
	AgentAttempts                   string
	AgentPollInterval               string
	AgentControlPlaneConnectTimeout string
	AgentControlPlaneRequestTimeout string
	AgentControlPlaneRetryCount     string
	AgentControlPlaneRetryDelay     string
	AgentWorkspaceRoot              string
	AgentRequiredBins               []string
	PublishCommitHookPolicy         string
	SchedulerMaxParallelTasks       string
	Executor                        map[string]any
	Repos                           map[string]projectPackageRepo
}

type projectPackageRepo struct {
	Path  string
	Label string
}

func loadProjectPackageConfig(packagePath string) (projectPackageConfig, error) {
	return loadProjectPackageConfigFile(filepath.Join(packagePath, "project.yaml"))
}

func loadProjectPackageConfigFile(projectFile string) (projectPackageConfig, error) {
	config := projectPackageConfig{Repos: map[string]projectPackageRepo{}}
	packagePath := filepath.Dir(projectFile)
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
	var rawPayload map[string]any
	if err := yaml.Unmarshal(body, &rawPayload); err != nil {
		return config, fmt.Errorf("parse project package config %s: %w", projectFile, err)
	}
	runtimePayload, _ := rawPayload["runtime"].(map[string]any)
	kanbanPayload, _ := rawPayload["kanban"].(map[string]any)
	agentPayload, _ := rawPayload["agent"].(map[string]any)
	config.SchemaVersion = scalarString(payload.SchemaVersion)
	config.PackageName = payload.Package.Name
	config.KanbanProject = payload.Kanban.Project
	config.KanbanLabels = payload.Kanban.Labels
	config.KanbanStatus = payload.Kanban.Selection.Status
	config.MaxSteps = scalarString(payload.Runtime.MaxSteps)
	config.AgentAttempts = scalarString(payload.Runtime.AgentAttempts)
	config.AgentPollInterval = scalarString(payload.Runtime.AgentPollInterval)
	config.AgentControlPlaneConnectTimeout = scalarString(payload.Runtime.AgentControlPlaneConnectTimeout)
	config.AgentControlPlaneRequestTimeout = scalarString(payload.Runtime.AgentControlPlaneRequestTimeout)
	config.AgentControlPlaneRetryCount = scalarString(payload.Runtime.AgentControlPlaneRetryCount)
	config.AgentControlPlaneRetryDelay = scalarString(payload.Runtime.AgentControlPlaneRetryDelay)
	config.AgentWorkspaceRoot = payload.Agent.WorkspaceRoot
	config.AgentRequiredBins = payload.Agent.RequiredBins
	config.PublishCommitHookPolicy = scalarString(payload.Publish.CommitHookPolicy)
	config.SchedulerMaxParallelTasks = scalarString(projectSchedulerRawMaxParallelTasks(runtimePayload))
	if strings.TrimSpace(config.SchemaVersion) == "" {
		return config, fmt.Errorf("project package config %s is missing schema_version", projectFile)
	}
	if config.SchemaVersion != "1" {
		return config, fmt.Errorf("project package config %s has unsupported schema_version: %s", projectFile, config.SchemaVersion)
	}
	if _, ok := kanbanPayload["bootstrap"]; ok {
		return config, fmt.Errorf("project package config %s has invalid kanban.bootstrap: kanban.bootstrap is no longer supported; define project labels in kanban.labels or repos.<slot>.label", projectFile)
	}
	if _, ok := runtimePayload["live_ref"]; ok {
		return config, fmt.Errorf("project package config %s has invalid runtime.live_ref: runtime.live_ref is no longer supported; use runtime.phases.merge.target_ref", projectFile)
	}
	if _, ok := runtimePayload["executor"]; ok {
		return config, fmt.Errorf("project package config %s has invalid runtime.executor: runtime.executor is no longer supported; use runtime.phases.implementation.executor", projectFile)
	}
	if _, ok := runtimePayload["surface"]; ok {
		return config, fmt.Errorf("project package config %s has invalid runtime.surface: runtime.surface is no longer supported; use runtime.phases", projectFile)
	}
	if _, ok := runtimePayload["merge"]; ok {
		return config, fmt.Errorf("project package config %s has invalid runtime.merge: runtime.merge is no longer supported; use runtime.phases.merge", projectFile)
	}
	if _, ok := agentPayload["workspace_cleanup_policy"]; ok {
		return config, fmt.Errorf("project package config %s has invalid agent.workspace_cleanup_policy: workspace cleanup policy is managed by A2O runtime and is not supported in project.yaml", projectFile)
	}
	if err := rejectMergeTarget(runtimePayload); err != nil {
		return config, fmt.Errorf("project package config %s has invalid runtime.phases.merge: %w", projectFile, err)
	}
	if err := rejectLegacyPhaseWorkspaceHook(runtimePayload); err != nil {
		return config, fmt.Errorf("project package config %s has invalid runtime.phases: %w", projectFile, err)
	}
	if err := validateProjectSchedulerConfig(runtimePayload); err != nil {
		return config, fmt.Errorf("project package config %s has invalid runtime.scheduler: %w", projectFile, err)
	}
	if err := validateProjectDeliveryConfig(runtimePayload); err != nil {
		return config, fmt.Errorf("project package config %s has invalid runtime.delivery: %w", projectFile, err)
	}
	if err := validateProjectPromptsConfig(runtimePayload, packagePath, projectRepoNames(payload.Repos)); err != nil {
		return config, fmt.Errorf("project package config %s has invalid runtime.prompts: %w", projectFile, err)
	}
	if err := validatePromptBackedPhaseSkills(runtimePayload); err != nil {
		return config, fmt.Errorf("project package config %s has invalid runtime.phases: %w", projectFile, err)
	}
	if err := validateProjectDocsConfig(rawPayload["docs"], packagePath, payload.Repos); err != nil {
		return config, fmt.Errorf("project package config %s has invalid docs: %w", projectFile, err)
	}
	if err := validatePublishConfig(rawPayload["publish"]); err != nil {
		return config, fmt.Errorf("project package config %s has invalid publish: %w", projectFile, err)
	}
	executor, err := buildProjectExecutorConfig(payload.Runtime.Phases)
	if err != nil {
		return config, fmt.Errorf("project package config %s has invalid runtime.phases: %w", projectFile, err)
	}
	config.Executor = executor
	liveRef, err := projectLiveRefFromMergePhase(payload.Runtime.Phases)
	if err != nil {
		return config, fmt.Errorf("project package config %s has invalid runtime.phases.merge: %w", projectFile, err)
	}
	config.LiveRef = liveRef
	for alias, repo := range payload.Repos {
		config.Repos[alias] = projectPackageRepo{Path: repo.Path, Label: repo.Label}
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

func buildProjectExecutorConfig(phases map[string]projectPackagePhaseYAML) (map[string]any, error) {
	if len(phases) == 0 {
		return nil, fmt.Errorf("runtime.phases must define implementation")
	}
	for phase := range phases {
		if !containsString([]string{"implementation", "review", "parent_review", "verification", "remediation", "metrics", "merge"}, phase) {
			return nil, fmt.Errorf("contains unknown phase: %s", phase)
		}
	}
	implementationPhase, ok := phases["implementation"]
	if !ok {
		return nil, fmt.Errorf("implementation.executor.command must be provided")
	}
	implementationExecutor := normalizeYAMLValue(implementationPhase.Executor)
	if len(implementationExecutor) == 0 {
		return nil, fmt.Errorf("implementation.executor.command must be provided")
	}
	if err := validateProjectAuthorExecutorConfig(implementationExecutor, "implementation.executor"); err != nil {
		return nil, err
	}
	expanded := map[string]any{
		"kind":             "command",
		"prompt_transport": "stdin-bundle",
		"result":           map[string]any{"mode": "file"},
		"schema":           map[string]any{"mode": "file"},
		"default_profile": map[string]any{
			"command": implementationExecutor["command"],
		},
		"phase_profiles": map[string]any{},
	}
	if env, ok := implementationExecutor["env"]; ok {
		expanded["default_profile"].(map[string]any)["env"] = env
	} else {
		expanded["default_profile"].(map[string]any)["env"] = map[string]any{}
	}
	phaseProfiles := expanded["phase_profiles"].(map[string]any)
	for _, phase := range []string{"review", "parent_review"} {
		phaseConfig, ok := phases[phase]
		if !ok || len(phaseConfig.Executor) == 0 {
			continue
		}
		executor := normalizeYAMLValue(phaseConfig.Executor)
		if err := validateProjectAuthorExecutorConfig(executor, phase+".executor"); err != nil {
			return nil, err
		}
		profile := map[string]any{"command": executor["command"]}
		if env, ok := executor["env"]; ok {
			profile["env"] = env
		} else {
			profile["env"] = map[string]any{}
		}
		phaseProfiles[phase] = profile
	}
	return expanded, nil
}

type projectPackageYAML struct {
	SchemaVersion any `yaml:"schema_version"`
	Package       struct {
		Name string `yaml:"name"`
	} `yaml:"package"`
	Kanban struct {
		Project   string   `yaml:"project"`
		Labels    []string `yaml:"labels"`
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
	Publish struct {
		CommitHookPolicy any `yaml:"commit_hook_policy"`
	} `yaml:"publish"`
	Runtime struct {
		MaxSteps                        any                                `yaml:"max_steps"`
		AgentAttempts                   any                                `yaml:"agent_attempts"`
		AgentPollInterval               any                                `yaml:"agent_poll_interval"`
		AgentControlPlaneConnectTimeout any                                `yaml:"agent_control_plane_connect_timeout"`
		AgentControlPlaneRequestTimeout any                                `yaml:"agent_control_plane_request_timeout"`
		AgentControlPlaneRetryCount     any                                `yaml:"agent_control_plane_retry_count"`
		AgentControlPlaneRetryDelay     any                                `yaml:"agent_control_plane_retry_delay"`
		Phases                          map[string]projectPackagePhaseYAML `yaml:"phases"`
	} `yaml:"runtime"`
}

type projectPackagePhaseYAML struct {
	Skill     any            `yaml:"skill"`
	Executor  map[string]any `yaml:"executor"`
	Commands  []string       `yaml:"commands"`
	Policy    any            `yaml:"policy"`
	TargetRef any            `yaml:"target_ref"`
}

func projectRepoNames(repos map[string]struct {
	Path  string `yaml:"path"`
	Label string `yaml:"label"`
}) []string {
	names := make([]string, 0, len(repos))
	for name := range repos {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func rejectLegacyPhaseWorkspaceHook(runtimePayload map[string]any) error {
	phases, ok := normalizeYAMLValue(runtimePayload["phases"]).(map[string]any)
	if !ok {
		return nil
	}
	for phaseName, phaseValue := range phases {
		phase, ok := normalizeYAMLValue(phaseValue).(map[string]any)
		if !ok {
			continue
		}
		if _, ok := phase["workspace_hook"]; ok {
			return fmt.Errorf("%s.workspace_hook is no longer supported; use phase commands or project package commands", phaseName)
		}
	}
	return nil
}

func validateProjectSchedulerConfig(runtimePayload map[string]any) error {
	rawScheduler, ok := runtimePayload["scheduler"]
	if !ok {
		return nil
	}
	scheduler, ok := schedulerMapping(rawScheduler)
	if !ok {
		return fmt.Errorf("must be a mapping")
	}
	rawMaxParallelTasks, ok := scheduler["max_parallel_tasks"]
	if !ok {
		return nil
	}
	maxParallelTasks, ok := schedulerInteger(rawMaxParallelTasks)
	if !ok {
		return fmt.Errorf("max_parallel_tasks must be an integer")
	}
	if maxParallelTasks < 1 {
		return fmt.Errorf("max_parallel_tasks must be greater than or equal to 1")
	}
	if maxParallelTasks > 1 {
		return fmt.Errorf("max_parallel_tasks > 1 is not supported yet; requires scheduler task claims, batch planning, and shared-ref publish/merge locks")
	}
	return nil
}

func projectSchedulerRawMaxParallelTasks(runtimePayload map[string]any) any {
	rawScheduler, ok := runtimePayload["scheduler"]
	if !ok {
		return nil
	}
	scheduler, ok := schedulerMapping(rawScheduler)
	if !ok {
		return nil
	}
	return scheduler["max_parallel_tasks"]
}

func schedulerMapping(value any) (map[string]any, bool) {
	switch typed := value.(type) {
	case map[string]any:
		return typed, true
	case map[any]any:
		out := map[string]any{}
		for key, nested := range typed {
			keyText, ok := key.(string)
			if !ok {
				return nil, false
			}
			out[keyText] = nested
		}
		return out, true
	default:
		return nil, false
	}
}

func schedulerInteger(value any) (int64, bool) {
	switch typed := value.(type) {
	case int:
		return int64(typed), true
	case int64:
		return typed, true
	default:
		return 0, false
	}
}

func validateProjectDeliveryConfig(runtimePayload map[string]any) error {
	rawDelivery, ok := runtimePayload["delivery"]
	if !ok || rawDelivery == nil {
		return nil
	}
	delivery, ok := normalizeYAMLValue(rawDelivery).(map[string]any)
	if !ok {
		return fmt.Errorf("must be a mapping")
	}
	mode := scalarString(delivery["mode"])
	if strings.TrimSpace(mode) == "" {
		return fmt.Errorf("mode must be provided")
	}
	remote, err := projectDeliveryOptionalString(delivery, "remote")
	if err != nil {
		return err
	}
	baseBranch, err := projectDeliveryOptionalString(delivery, "base_branch")
	if err != nil {
		return err
	}
	if _, err := projectDeliveryOptionalString(delivery, "branch_prefix"); err != nil {
		return err
	}
	if _, ok := delivery["push"]; ok {
		if _, ok := delivery["push"].(bool); !ok {
			return fmt.Errorf("push must be true or false")
		}
	}
	if err := validateProjectDeliverySync(delivery["sync"]); err != nil {
		return fmt.Errorf("sync.%w", err)
	}
	if err := validateProjectDeliveryAfterPush(delivery["after_push"]); err != nil {
		return err
	}
	switch mode {
	case "local_merge":
		return nil
	case "remote_branch":
	default:
		return fmt.Errorf("unsupported mode: %s", mode)
	}
	if remote == "" {
		return fmt.Errorf("remote must be provided for remote_branch mode")
	}
	if baseBranch == "" {
		return fmt.Errorf("base_branch must be provided for remote_branch mode")
	}
	return nil
}

func projectDeliveryOptionalString(delivery map[string]any, key string) (string, error) {
	raw, ok := delivery[key]
	if !ok || raw == nil {
		return "", nil
	}
	value, ok := raw.(string)
	if !ok {
		return "", fmt.Errorf("%s must be a string", key)
	}
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return "", fmt.Errorf("%s must not be blank", key)
	}
	return trimmed, nil
}

func validateProjectDeliverySync(rawSync any) error {
	if rawSync == nil {
		return nil
	}
	sync, ok := normalizeYAMLValue(rawSync).(map[string]any)
	if !ok {
		return fmt.Errorf("must be a mapping")
	}
	for _, key := range []string{"before_start", "before_resume", "before_push"} {
		if _, ok := sync[key]; !ok {
			continue
		}
		value := scalarString(sync[key])
		if strings.TrimSpace(value) == "" {
			return fmt.Errorf("%s must not be blank", key)
		}
		if value != "fetch" {
			return fmt.Errorf("%s must be fetch", key)
		}
	}
	if _, ok := sync["integrate_base"]; ok {
		value := scalarString(sync["integrate_base"])
		if !containsString([]string{"none", "merge", "rebase"}, value) {
			return fmt.Errorf("integrate_base has unsupported value: %s", value)
		}
	}
	if _, ok := sync["conflict_policy"]; ok {
		value := scalarString(sync["conflict_policy"])
		if value != "stop" {
			return fmt.Errorf("conflict_policy has unsupported value: %s", value)
		}
	}
	return nil
}

func validateProjectDeliveryAfterPush(rawAfterPush any) error {
	if rawAfterPush == nil {
		return nil
	}
	afterPush, ok := normalizeYAMLValue(rawAfterPush).(map[string]any)
	if !ok {
		return fmt.Errorf("after_push must be a mapping")
	}
	rawCommand, ok := normalizeYAMLValue(afterPush["command"]).([]any)
	if !ok || len(rawCommand) == 0 {
		return fmt.Errorf("after_push.command must be a non-empty array of strings")
	}
	for index, rawPart := range rawCommand {
		part, ok := rawPart.(string)
		if !ok || strings.TrimSpace(part) == "" {
			return fmt.Errorf("after_push.command[%d] must be a non-empty string", index)
		}
	}
	return nil
}

func validatePublishConfig(rawPublish any) error {
	if rawPublish == nil {
		return nil
	}
	publish, ok := normalizeYAMLValue(rawPublish).(map[string]any)
	if !ok {
		return fmt.Errorf("must be a mapping")
	}
	for key := range publish {
		if key != "commit_hook_policy" {
			return fmt.Errorf("%s is not supported", key)
		}
	}
	policy := scalarString(publish["commit_hook_policy"])
	if policy == "" {
		return nil
	}
	return publishpolicy.ValidateConfiguredCommitHook(policy)
}

func rejectMergeTarget(runtimePayload map[string]any) error {
	phases, ok := normalizeYAMLValue(runtimePayload["phases"]).(map[string]any)
	if !ok {
		return nil
	}
	mergePhase, ok := phases["merge"].(map[string]any)
	if !ok {
		return nil
	}
	if _, ok := mergePhase["target"]; ok {
		return fmt.Errorf("target is no longer supported; A2O derives merge target from task topology")
	}
	return nil
}

func projectLiveRefFromMergePhase(phases map[string]projectPackagePhaseYAML) (string, error) {
	mergePhase, ok := phases["merge"]
	if !ok {
		return "", fmt.Errorf("policy and target_ref must be provided")
	}
	if err := validateMergePolicy(mergePhase.Policy); err != nil {
		return "", err
	}
	ref := targetRefDefaultValue(mergePhase.TargetRef)
	if strings.TrimSpace(ref) == "" {
		return "", fmt.Errorf("target_ref must be provided")
	}
	return ref, nil
}

func validateMergePolicy(value any) error {
	policy := targetRefDefaultValue(value)
	if strings.TrimSpace(policy) == "" {
		return fmt.Errorf("policy must be provided")
	}
	switch policy {
	case "ff_only", "ff_or_merge", "no_ff":
		return nil
	default:
		return fmt.Errorf("unsupported policy: %s", policy)
	}
}

func targetRefDefaultValue(value any) string {
	switch typed := value.(type) {
	case map[string]any:
		return targetRefDefaultValue(typed["default"])
	case map[any]any:
		return targetRefDefaultValue(typed["default"])
	default:
		return scalarString(value)
	}
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

func validateProjectAuthorExecutorConfig(executor map[string]any, label string) error {
	if err := rejectInternalProjectExecutorKeys(executor, label); err != nil {
		return err
	}
	if err := validateProjectExecutorProfile(executor, label); err != nil {
		return err
	}
	if _, ok := executor["phase_profiles"]; ok {
		return fmt.Errorf("%s.phase_profiles is internal; define phase-specific executors under runtime.phases", label)
	}
	return nil
}

func rejectInternalProjectExecutorKeys(executor map[string]any, label string) error {
	for _, key := range []string{"kind", "prompt_transport", "result", "schema", "default_profile"} {
		if _, ok := executor[key]; ok {
			return fmt.Errorf("%s.%s is internal; use runtime.phases.<phase>.executor.command in project.yaml", label, key)
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
