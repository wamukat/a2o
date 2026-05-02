package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

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
	SchedulerMaxParallelTasks       string
	Executor                        map[string]any
	Repos                           map[string]projectPackageRepo
}

var projectDocsMachineKeyPattern = regexp.MustCompile(`^[a-z][a-z0-9_]*$`)

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

func validateProjectPromptsConfig(runtimePayload map[string]any, packagePath string, repoNames []string) error {
	rawPrompts, ok := runtimePayload["prompts"]
	if !ok {
		return nil
	}
	prompts, ok := normalizeYAMLValue(rawPrompts).(map[string]any)
	if !ok {
		return fmt.Errorf("must be a mapping")
	}
	if rawSystem, ok := prompts["system"]; ok {
		system, ok := normalizeYAMLValue(rawSystem).(map[string]any)
		if !ok {
			return fmt.Errorf("system must be a mapping")
		}
		if err := validatePromptPath(system["file"], "system.file", packagePath, true); err != nil {
			return err
		}
	}
	basePhases, _ := normalizeYAMLValue(prompts["phases"]).(map[string]any)
	if err := validatePromptPhaseMapping(prompts["phases"], "phases", packagePath); err != nil {
		return err
	}
	if rawRepoSlots, ok := prompts["repoSlots"]; ok {
		repoSlots, ok := normalizeYAMLValue(rawRepoSlots).(map[string]any)
		if !ok {
			return fmt.Errorf("repoSlots must be a mapping")
		}
		for slot, rawSlotConfig := range repoSlots {
			if strings.TrimSpace(slot) == "" {
				return fmt.Errorf("repoSlots keys must be non-empty strings")
			}
			if len(repoNames) > 0 && !containsString(repoNames, slot) {
				return fmt.Errorf("repoSlots.%s must match a repos entry", slot)
			}
			slotConfig, ok := normalizeYAMLValue(rawSlotConfig).(map[string]any)
			if !ok {
				return fmt.Errorf("repoSlots.%s must be a mapping", slot)
			}
			if err := validatePromptPhaseMapping(slotConfig["phases"], "repoSlots."+slot+".phases", packagePath); err != nil {
				return err
			}
			slotPhases, _ := normalizeYAMLValue(slotConfig["phases"]).(map[string]any)
			if err := validateRepoSlotPromptSkillAddons(slot, basePhases, slotPhases); err != nil {
				return err
			}
		}
	}
	return nil
}

func validatePromptBackedPhaseSkills(runtimePayload map[string]any) error {
	phases, _ := normalizeYAMLValue(runtimePayload["phases"]).(map[string]any)
	prompts, _ := normalizeYAMLValue(runtimePayload["prompts"]).(map[string]any)
	promptPhases, _ := normalizeYAMLValue(prompts["phases"]).(map[string]any)
	for _, phaseName := range []string{"implementation", "review"} {
		phase, ok := normalizeYAMLValue(phases[phaseName]).(map[string]any)
		if !ok {
			continue
		}
		if _, hasSkill := phase["skill"]; hasSkill {
			continue
		}
		if promptPhaseHasAuthoringContent(promptPhases[phaseName]) {
			continue
		}
		return fmt.Errorf("%s.skill must be provided", phaseName)
	}
	return nil
}

func promptPhaseHasAuthoringContent(rawPhase any) bool {
	phase, ok := normalizeYAMLValue(rawPhase).(map[string]any)
	if !ok {
		return false
	}
	if strings.TrimSpace(scalarString(phase["prompt"])) != "" {
		return true
	}
	skills, ok := normalizeYAMLValue(phase["skills"]).([]any)
	return ok && len(skills) > 0
}

func validatePromptPhaseMapping(rawPhases any, label string, packagePath string) error {
	if rawPhases == nil {
		return nil
	}
	phases, ok := normalizeYAMLValue(rawPhases).(map[string]any)
	if !ok {
		return fmt.Errorf("%s must be a mapping", label)
	}
	for phase, rawPhaseConfig := range phases {
		if strings.TrimSpace(phase) == "" {
			return fmt.Errorf("%s keys must be non-empty strings", label)
		}
		if !containsString([]string{"implementation", "implementation_rework", "review", "parent_review", "verification", "remediation", "metrics", "decomposition"}, phase) {
			return fmt.Errorf("%s.%s is not a supported prompt phase", label, phase)
		}
		phaseConfig, ok := normalizeYAMLValue(rawPhaseConfig).(map[string]any)
		if !ok {
			return fmt.Errorf("%s.%s must be a mapping", label, phase)
		}
		if _, ok := phaseConfig["childDraftTemplate"]; ok && phase != "decomposition" {
			return fmt.Errorf("%s.%s.childDraftTemplate is only supported for decomposition", label, phase)
		}
		if err := validatePromptPath(phaseConfig["prompt"], label+"."+phase+".prompt", packagePath, false); err != nil {
			return err
		}
		if err := validatePromptStringList(phaseConfig["skills"], label+"."+phase+".skills", packagePath); err != nil {
			return err
		}
		if err := validatePromptPath(phaseConfig["childDraftTemplate"], label+"."+phase+".childDraftTemplate", packagePath, false); err != nil {
			return err
		}
	}
	return nil
}

func validatePromptPath(rawPath any, label string, packagePath string, required bool) error {
	if rawPath == nil {
		if required {
			return fmt.Errorf("%s must be a non-empty string", label)
		}
		return nil
	}
	path, ok := rawPath.(string)
	if !ok || strings.TrimSpace(path) == "" {
		return fmt.Errorf("%s must be a non-empty string", label)
	}
	if filepath.IsAbs(path) {
		return fmt.Errorf("%s must be relative to the project package root", label)
	}
	root, err := filepath.Abs(packagePath)
	if err != nil {
		return fmt.Errorf("resolve project package root: %w", err)
	}
	absPath, err := filepath.Abs(filepath.Join(root, path))
	if err != nil {
		return fmt.Errorf("%s resolve path: %w", label, err)
	}
	if absPath != root && !strings.HasPrefix(absPath, root+string(os.PathSeparator)) {
		return fmt.Errorf("%s must stay inside the project package root", label)
	}
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return fmt.Errorf("resolve project package root: %w", err)
	}
	realPath, err := filepath.EvalSymlinks(absPath)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("%s file not found: %s", label, path)
		}
		return fmt.Errorf("%s resolve file: %w", label, err)
	}
	if realPath != realRoot && !strings.HasPrefix(realPath, realRoot+string(os.PathSeparator)) {
		return fmt.Errorf("%s must stay inside the project package root", label)
	}
	info, err := os.Stat(absPath)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("%s file not found: %s", label, path)
		}
		return fmt.Errorf("%s inspect file: %w", label, err)
	}
	if info.IsDir() {
		return fmt.Errorf("%s must reference a file: %s", label, path)
	}
	body, err := os.ReadFile(absPath)
	if err != nil {
		return fmt.Errorf("%s read file: %w", label, err)
	}
	if !utf8.Valid(body) {
		return fmt.Errorf("%s must be UTF-8 text: %s", label, path)
	}
	return nil
}

func validatePromptStringList(rawList any, label string, packagePath string) error {
	if rawList == nil {
		return nil
	}
	list, ok := normalizeYAMLValue(rawList).([]any)
	if !ok {
		return fmt.Errorf("%s must be an array of non-empty strings", label)
	}
	seen := map[string]bool{}
	for index, rawEntry := range list {
		entry, ok := rawEntry.(string)
		if !ok || strings.TrimSpace(entry) == "" {
			return fmt.Errorf("%s[%d] must be a non-empty string", label, index)
		}
		if seen[entry] {
			return fmt.Errorf("%s contains duplicate skill file: %s", label, entry)
		}
		seen[entry] = true
		if err := validatePromptPath(entry, fmt.Sprintf("%s[%d]", label, index), packagePath, true); err != nil {
			return err
		}
	}
	return nil
}

func validateRepoSlotPromptSkillAddons(slot string, basePhases map[string]any, slotPhases map[string]any) error {
	for phase, rawSlotPhase := range slotPhases {
		slotSkills := promptPhaseSkillFiles(rawSlotPhase)
		if len(slotSkills) == 0 {
			continue
		}
		basePhase := promptBasePhaseForAddon(phase, basePhases)
		baseSkills := promptPhaseSkillFiles(basePhases[basePhase])
		for _, skill := range slotSkills {
			if containsString(baseSkills, skill) {
				return fmt.Errorf("repoSlots.%s.phases.%s.skills duplicates phases.%s.skills entry: %s", slot, phase, basePhase, skill)
			}
		}
	}
	return nil
}

func validateProjectDocsConfig(rawDocs any, packagePath string, repos map[string]struct {
	Path  string `yaml:"path"`
	Label string `yaml:"label"`
}) error {
	if rawDocs == nil {
		return nil
	}
	docs, ok := normalizeYAMLValue(rawDocs).(map[string]any)
	if !ok {
		return fmt.Errorf("must be a mapping")
	}
	repoNames := projectRepoNames(repos)
	if rawSurfaces, ok := docs["surfaces"]; ok {
		surfaces, ok := normalizeYAMLValue(rawSurfaces).(map[string]any)
		if !ok || len(surfaces) == 0 {
			return fmt.Errorf("surfaces must be a non-empty mapping")
		}
		for id, rawSurface := range surfaces {
			if !projectDocsMachineKey(id) {
				return fmt.Errorf("surfaces.%s id must be a non-empty machine-readable key", id)
			}
			surface, ok := normalizeYAMLValue(rawSurface).(map[string]any)
			if !ok {
				return fmt.Errorf("surfaces.%s must be a mapping", id)
			}
			repoSlot, err := projectDocsRepoSlot(surface["repoSlot"], repoNames, "surfaces.%s.repoSlot", id)
			if err != nil {
				return err
			}
			if repoSlot == "" {
				repoSlot, err = projectDocsRepoSlot(docs["repoSlot"], repoNames, "repoSlot")
				if err != nil {
					return err
				}
			}
			if repoSlot == "" && len(repoNames) == 1 {
				repoSlot = repoNames[0]
			}
			if repoSlot == "" && len(repoNames) > 1 {
				return fmt.Errorf("surfaces.%s.repoSlot must be provided when multiple repos are declared", id)
			}
			repoRoot := projectDocsRepoRoot(packagePath, repos, repoSlot)
			if err := validateProjectDocsPath(surface["root"], "surfaces."+id+".root", repoRoot, true); err != nil {
				return err
			}
			if err := validateProjectDocsPath(surface["index"], "surfaces."+id+".index", repoRoot, false); err != nil {
				return err
			}
			if err := validateProjectDocsCategories(surface["categories"], repoRoot, "surfaces."+id+".categories"); err != nil {
				return err
			}
			if err := validateProjectDocsLanguages(firstPresent(surface["languages"], docs["languages"])); err != nil {
				return err
			}
			if err := validateProjectDocsStringMap(firstPresent(surface["policy"], docs["policy"]), "surfaces."+id+".policy"); err != nil {
				return err
			}
			if err := validateProjectDocsStringMap(firstPresent(surface["impactPolicy"], docs["impactPolicy"]), "surfaces."+id+".impactPolicy"); err != nil {
				return err
			}
		}
		if err := validateProjectDocsAuthorities(docs["authorities"], packagePath, repos, docs, surfaces); err != nil {
			return err
		}
		return nil
	}
	repoSlot := ""
	if rawRepoSlot, ok := docs["repoSlot"]; ok {
		value, ok := rawRepoSlot.(string)
		if !ok || strings.TrimSpace(value) == "" {
			return fmt.Errorf("repoSlot must be a non-empty string")
		}
		repoSlot = strings.TrimSpace(value)
		if len(repoNames) > 0 && !containsString(repoNames, repoSlot) {
			return fmt.Errorf("repoSlot must match a repos entry: %s", repoSlot)
		}
	} else if len(repoNames) == 1 {
		repoSlot = repoNames[0]
	} else if len(repoNames) > 1 {
		return fmt.Errorf("repoSlot must be provided when multiple repos are declared")
	}
	repoRoot := projectDocsRepoRoot(packagePath, repos, repoSlot)
	if err := validateProjectDocsPath(docs["root"], "root", repoRoot, true); err != nil {
		return err
	}
	if err := validateProjectDocsPath(docs["index"], "index", repoRoot, false); err != nil {
		return err
	}
	if err := validateProjectDocsCategories(docs["categories"], repoRoot, "categories"); err != nil {
		return err
	}
	if err := validateProjectDocsLanguages(docs["languages"]); err != nil {
		return err
	}
	if err := validateProjectDocsStringMap(docs["policy"], "policy"); err != nil {
		return err
	}
	if err := validateProjectDocsStringMap(docs["impactPolicy"], "impactPolicy"); err != nil {
		return err
	}
	if err := validateProjectDocsAuthorities(docs["authorities"], packagePath, repos, docs, nil); err != nil {
		return err
	}
	return nil
}

func projectDocsRepoSlot(rawSlot any, repoNames []string, label string, args ...any) (string, error) {
	if len(args) > 0 {
		label = fmt.Sprintf(label, args...)
	}
	if rawSlot == nil {
		return "", nil
	}
	value, ok := rawSlot.(string)
	if !ok || strings.TrimSpace(value) == "" {
		return "", fmt.Errorf("%s must be a non-empty string", label)
	}
	slot := strings.TrimSpace(value)
	if len(repoNames) > 0 && !containsString(repoNames, slot) {
		return "", fmt.Errorf("%s must match a repos entry: %s", label, slot)
	}
	return slot, nil
}

func firstPresent(primary any, fallback any) any {
	if primary != nil {
		return primary
	}
	return fallback
}

func projectDocsRepoRoot(packagePath string, repos map[string]struct {
	Path  string `yaml:"path"`
	Label string `yaml:"label"`
}, repoSlot string) string {
	repo, ok := repos[repoSlot]
	if !ok {
		return ""
	}
	if strings.TrimSpace(repo.Path) == "" {
		return ""
	}
	if filepath.IsAbs(repo.Path) {
		return filepath.Clean(repo.Path)
	}
	return filepath.Clean(filepath.Join(packagePath, repo.Path))
}

func validateProjectDocsCategories(rawCategories any, repoRoot string, label string) error {
	if rawCategories == nil {
		return nil
	}
	categories, ok := normalizeYAMLValue(rawCategories).(map[string]any)
	if !ok {
		return fmt.Errorf("%s must be a mapping", label)
	}
	for id, rawCategory := range categories {
		if !projectDocsMachineKey(id) {
			return fmt.Errorf("%s.%s id must be a non-empty machine-readable key", label, id)
		}
		category, ok := normalizeYAMLValue(rawCategory).(map[string]any)
		if !ok {
			return fmt.Errorf("%s.%s must be a mapping", label, id)
		}
		if err := validateProjectDocsPath(category["path"], label+"."+id+".path", repoRoot, true); err != nil {
			return err
		}
		if err := validateProjectDocsPath(category["index"], label+"."+id+".index", repoRoot, false); err != nil {
			return err
		}
	}
	return nil
}

func validateProjectDocsAuthorities(rawAuthorities any, packagePath string, repos map[string]struct {
	Path  string `yaml:"path"`
	Label string `yaml:"label"`
}, docs map[string]any, rawSurfaces map[string]any) error {
	if rawAuthorities == nil {
		return nil
	}
	authorities, ok := normalizeYAMLValue(rawAuthorities).(map[string]any)
	if !ok {
		return fmt.Errorf("authorities must be a mapping")
	}
	for id, rawAuthority := range authorities {
		if !projectDocsMachineKey(id) {
			return fmt.Errorf("authorities.%s id must be a non-empty machine-readable key", id)
		}
		authority, ok := normalizeYAMLValue(rawAuthority).(map[string]any)
		if !ok {
			return fmt.Errorf("authorities.%s must be a mapping", id)
		}
		repoSlot, err := projectDocsAuthorityRepoSlot(authority, docs, rawSurfaces, projectRepoNames(repos), id)
		if err != nil {
			return err
		}
		repoRoot := projectDocsRepoRoot(packagePath, repos, repoSlot)
		generated, _ := authority["generated"].(bool)
		if err := validateProjectDocsPath(authority["source"], "authorities."+id+".source", repoRoot, !generated); err != nil {
			return err
		}
		if !generated && repoRoot != "" {
			source, _ := authority["source"].(string)
			if strings.TrimSpace(source) != "" {
				sourcePath := filepath.Join(repoRoot, source)
				if _, err := os.Stat(sourcePath); err != nil {
					if os.IsNotExist(err) {
						return fmt.Errorf("authorities.%s.source file not found: %s", id, source)
					}
					return fmt.Errorf("authorities.%s.source inspect file: %w", id, err)
				}
			}
		}
		if rawDocsPaths, ok := authority["docs"]; ok {
			switch docsPaths := normalizeYAMLValue(rawDocsPaths).(type) {
			case string:
				if err := validateProjectDocsPath(docsPaths, "authorities."+id+".docs", repoRoot, false); err != nil {
					return err
				}
			case []any:
				for index, entry := range docsPaths {
					if docEntry, ok := normalizeYAMLValue(entry).(map[string]any); ok {
						surfaceID, _ := docEntry["surface"].(string)
						if strings.TrimSpace(surfaceID) == "" {
							return fmt.Errorf("authorities.%s.docs[%d].surface must be a non-empty string", id, index)
						}
						surfaceRoot, err := projectDocsSurfaceRepoRoot(packagePath, repos, docs, rawSurfaces, strings.TrimSpace(surfaceID))
						if err != nil {
							return fmt.Errorf("authorities.%s.docs[%d]: %w", id, index, err)
						}
						if err := validateProjectDocsPath(docEntry["path"], fmt.Sprintf("authorities.%s.docs[%d].path", id, index), surfaceRoot, true); err != nil {
							return err
						}
						continue
					}
					if err := validateProjectDocsPath(entry, fmt.Sprintf("authorities.%s.docs[%d]", id, index), repoRoot, true); err != nil {
						return err
					}
				}
			default:
				return fmt.Errorf("authorities.%s.docs must be a string or array of strings/maps", id)
			}
		}
	}
	return nil
}

func projectDocsAuthorityRepoSlot(authority map[string]any, docs map[string]any, rawSurfaces map[string]any, repoNames []string, id string) (string, error) {
	if slot, err := projectDocsRepoSlot(authority["repoSlot"], repoNames, "authorities."+id+".repoSlot"); err != nil || slot != "" {
		return slot, err
	}
	if slot, err := projectDocsRepoSlot(docs["repoSlot"], repoNames, "repoSlot"); err != nil || slot != "" {
		return slot, err
	}
	if len(repoNames) == 1 {
		return repoNames[0], nil
	}
	if len(rawSurfaces) > 0 {
		return "", fmt.Errorf("authorities.%s.repoSlot must be provided when docs.surfaces and multiple repos are declared", id)
	}
	return "", nil
}

func projectDocsSurfaceRepoRoot(packagePath string, repos map[string]struct {
	Path  string `yaml:"path"`
	Label string `yaml:"label"`
}, docs map[string]any, rawSurfaces map[string]any, surfaceID string) (string, error) {
	rawSurface, ok := rawSurfaces[surfaceID]
	if !ok {
		return "", fmt.Errorf("surface not found: %s", surfaceID)
	}
	surface, ok := normalizeYAMLValue(rawSurface).(map[string]any)
	if !ok {
		return "", fmt.Errorf("surfaces.%s must be a mapping", surfaceID)
	}
	repoNames := projectRepoNames(repos)
	slot, err := projectDocsRepoSlot(surface["repoSlot"], repoNames, "surfaces."+surfaceID+".repoSlot")
	if err != nil {
		return "", err
	}
	if slot == "" {
		slot, err = projectDocsRepoSlot(docs["repoSlot"], repoNames, "repoSlot")
		if err != nil {
			return "", err
		}
	}
	if slot == "" && len(repoNames) == 1 {
		slot = repoNames[0]
	}
	if slot == "" && len(repoNames) > 1 {
		return "", fmt.Errorf("surfaces.%s.repoSlot must be provided when multiple repos are declared", surfaceID)
	}
	return projectDocsRepoRoot(packagePath, repos, slot), nil
}

func validateProjectDocsLanguages(rawLanguages any) error {
	if rawLanguages == nil {
		return nil
	}
	languages, ok := normalizeYAMLValue(rawLanguages).(map[string]any)
	if !ok {
		return fmt.Errorf("languages must be a mapping")
	}
	if rawPrimary, ok := languages["primary"]; ok {
		primary, ok := rawPrimary.(string)
		if !ok || strings.TrimSpace(primary) == "" {
			return fmt.Errorf("languages.primary must be a non-empty string")
		}
	}
	for _, key := range []string{"secondary", "required"} {
		rawList, ok := languages[key]
		if !ok {
			continue
		}
		list, ok := normalizeYAMLValue(rawList).([]any)
		if !ok {
			return fmt.Errorf("languages.%s must be an array of non-empty strings", key)
		}
		for index, rawEntry := range list {
			entry, ok := rawEntry.(string)
			if !ok || strings.TrimSpace(entry) == "" {
				return fmt.Errorf("languages.%s[%d] must be a non-empty string", key, index)
			}
		}
	}
	return nil
}

func validateProjectDocsStringMap(rawMap any, label string) error {
	if rawMap == nil {
		return nil
	}
	values, ok := normalizeYAMLValue(rawMap).(map[string]any)
	if !ok {
		return fmt.Errorf("%s must be a mapping", label)
	}
	for key := range values {
		if strings.TrimSpace(key) == "" {
			return fmt.Errorf("%s keys must be non-empty strings", label)
		}
	}
	return nil
}

func validateProjectDocsPath(rawPath any, label string, repoRoot string, required bool) error {
	if rawPath == nil {
		if required {
			return fmt.Errorf("%s must be a non-empty repo-slot-relative path", label)
		}
		return nil
	}
	path, ok := rawPath.(string)
	if !ok || strings.TrimSpace(path) == "" {
		return fmt.Errorf("%s must be a non-empty repo-slot-relative path", label)
	}
	if filepath.IsAbs(path) {
		return fmt.Errorf("%s must be relative to the docs repo slot", label)
	}
	for _, part := range strings.FieldsFunc(filepath.ToSlash(path), func(r rune) bool { return r == '/' }) {
		if part == ".." {
			return fmt.Errorf("%s must stay inside the docs repo slot", label)
		}
	}
	if repoRoot == "" {
		return nil
	}
	absRepoRoot, err := filepath.Abs(repoRoot)
	if err != nil {
		return fmt.Errorf("resolve docs repo slot root: %w", err)
	}
	absPath, err := filepath.Abs(filepath.Join(absRepoRoot, path))
	if err != nil {
		return fmt.Errorf("%s resolve path: %w", label, err)
	}
	if absPath != absRepoRoot && !strings.HasPrefix(absPath, absRepoRoot+string(os.PathSeparator)) {
		return fmt.Errorf("%s must stay inside the docs repo slot", label)
	}
	realRoot, err := filepath.EvalSymlinks(absRepoRoot)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("resolve docs repo slot root: %w", err)
	}
	existingPath, err := nearestExistingPath(absPath)
	if err != nil {
		return fmt.Errorf("%s inspect path: %w", label, err)
	}
	realExistingPath, err := filepath.EvalSymlinks(existingPath)
	if err != nil {
		return fmt.Errorf("%s resolve path: %w", label, err)
	}
	if realExistingPath != realRoot && !strings.HasPrefix(realExistingPath, realRoot+string(os.PathSeparator)) {
		return fmt.Errorf("%s must stay inside the docs repo slot", label)
	}
	return nil
}

func nearestExistingPath(path string) (string, error) {
	current := path
	for {
		if _, err := os.Lstat(current); err == nil {
			return current, nil
		} else if !os.IsNotExist(err) {
			return "", err
		}
		parent := filepath.Dir(current)
		if parent == current {
			return "", os.ErrNotExist
		}
		current = parent
	}
}

func projectDocsMachineKey(value string) bool {
	if strings.TrimSpace(value) == "" {
		return false
	}
	return projectDocsMachineKeyPattern.MatchString(value)
}

func promptBasePhaseForAddon(phase string, basePhases map[string]any) string {
	if phase == "implementation_rework" {
		if len(promptPhaseSkillFiles(basePhases["implementation_rework"])) == 0 && promptPhaseConfigEmptyRaw(basePhases["implementation_rework"]) {
			if !promptPhaseConfigEmptyRaw(basePhases["implementation"]) {
				return "implementation"
			}
		}
	}
	return phase
}

func promptPhaseConfigEmptyRaw(rawPhase any) bool {
	phase, ok := normalizeYAMLValue(rawPhase).(map[string]any)
	if !ok {
		return true
	}
	prompt, _ := phase["prompt"].(string)
	childDraftTemplate, _ := phase["childDraftTemplate"].(string)
	return strings.TrimSpace(prompt) == "" && strings.TrimSpace(childDraftTemplate) == "" && len(promptPhaseSkillFiles(rawPhase)) == 0
}

func promptPhaseSkillFiles(rawPhase any) []string {
	phase, ok := normalizeYAMLValue(rawPhase).(map[string]any)
	if !ok {
		return nil
	}
	rawSkills, ok := normalizeYAMLValue(phase["skills"]).([]any)
	if !ok {
		return nil
	}
	skills := make([]string, 0, len(rawSkills))
	for _, rawSkill := range rawSkills {
		skill, ok := rawSkill.(string)
		if ok {
			skills = append(skills, skill)
		}
	}
	return skills
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
