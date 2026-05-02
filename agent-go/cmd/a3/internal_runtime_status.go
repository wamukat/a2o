package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
)

func runRuntimeStatus(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime status", flag.ContinueOnError)
	flags.SetOutput(stderr)
	projectKey := flags.String("project", "", "runtime project key for read-only status")
	allProjects := flags.Bool("all-projects", false, "show read-only status for every project in the runtime project registry")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	if *allProjects {
		if strings.TrimSpace(*projectKey) != "" {
			return fmt.Errorf("--all-projects cannot be combined with --project")
		}
		return runRuntimeStatusAllProjects(runner, stdout)
	}

	context, configPath, err := loadProjectRuntimeContextFromWorkingTree(*projectKey)
	if err != nil {
		return err
	}
	return printRuntimeStatusForContext(context, configPath, runner, stdout)
}

func runRuntimeStatusAllProjects(runner commandRunner, stdout io.Writer) error {
	registryPath, registry, err := loadProjectRegistryFromWorkingTree("--all-projects")
	if err != nil {
		return err
	}
	for _, key := range sortedProjectKeys(registry) {
		context, err := projectRuntimeContextFromRegistry(registryPath, registry, key)
		if err != nil {
			fmt.Fprintf(stdout, "project_key=%s runtime_status_error=%s\n", key, singleLine(err.Error()))
			continue
		}
		var projectOutput bytes.Buffer
		if err := printRuntimeStatusForContext(context, registryPath, runner, &projectOutput); err != nil {
			fmt.Fprintf(stdout, "project_key=%s runtime_status_error=%s\n", context.ProjectKey, singleLine(err.Error()))
			continue
		}
		for _, line := range strings.Split(strings.TrimRight(projectOutput.String(), "\n"), "\n") {
			if strings.TrimSpace(line) == "" {
				continue
			}
			fmt.Fprintf(stdout, "project_key=%s %s\n", context.ProjectKey, line)
		}
	}
	return nil
}

func loadProjectRegistryFromWorkingTree(optionName string) (string, *runtimeProjectRegistry, error) {
	start, err := os.Getwd()
	if err != nil {
		return "", nil, fmt.Errorf("get working directory: %w", err)
	}
	registryPath, err := findProjectRegistry(start)
	if err != nil {
		return "", nil, fmt.Errorf("%s requires %s: %w", optionName, projectRegistryRelativePath, err)
	}
	registry, err := readProjectRegistry(registryPath)
	if err != nil {
		return "", nil, err
	}
	return registryPath, registry, nil
}

func sortedProjectKeys(registry *runtimeProjectRegistry) []string {
	keys := make([]string, 0, len(registry.Projects))
	for key := range registry.Projects {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func validateAllProjectLifecycleSurfaces(registryPath string, registry *runtimeProjectRegistry) error {
	composeOwners := map[string]string{}
	agentPortOwners := map[string]string{}
	issues := []string{}
	for _, key := range sortedProjectKeys(registry) {
		context, err := projectRuntimeContextFromRegistry(registryPath, registry, key)
		if err != nil {
			issues = append(issues, fmt.Sprintf("project %s invalid: %s", key, singleLine(err.Error())))
			continue
		}
		effectiveConfig := applyAgentInstallOverrides(context.Config, "", "", "")
		composeProject := strings.TrimSpace(effectiveConfig.ComposeProject)
		if composeProject == "" {
			issues = append(issues, fmt.Sprintf("project %s has empty compose_project", context.ProjectKey))
		} else if owner, exists := composeOwners[composeProject]; exists {
			issues = append(issues, fmt.Sprintf("projects %s and %s share compose_project %q", owner, context.ProjectKey, composeProject))
		} else {
			composeOwners[composeProject] = context.ProjectKey
		}
		agentPort := effectiveRuntimeAgentPort(effectiveConfig)
		if agentPort == "" {
			issues = append(issues, fmt.Sprintf("project %s has empty agent_port", context.ProjectKey))
		} else if owner, exists := agentPortOwners[agentPort]; exists {
			issues = append(issues, fmt.Sprintf("projects %s and %s share agent_port %q", owner, context.ProjectKey, agentPort))
		} else {
			agentPortOwners[agentPort] = context.ProjectKey
		}
	}
	if len(issues) > 0 {
		return fmt.Errorf("multi-project lifecycle requires isolated compose_project and agent_port values: %s", strings.Join(issues, "; "))
	}
	return nil
}

func effectiveRuntimeAgentPort(config runtimeInstanceConfig) string {
	return envDefaultCompat("A2O_BUNDLE_AGENT_PORT", "A3_BUNDLE_AGENT_PORT", envDefaultValue(config.AgentPort, "7393"))
}

func printRuntimeStatusForContext(context *projectRuntimeContext, configPath string, runner commandRunner, stdout io.Writer) error {
	effectiveConfig := applyAgentInstallOverrides(context.Config, "", "", "")
	paths := schedulerPaths(effectiveConfig)
	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", publicInstanceConfigPath(configPath))
	fmt.Fprintf(stdout, "runtime_project_key=%s\n", context.ProjectKey)
	if context.KanbanIdentity.BoardID != 0 {
		fmt.Fprintf(stdout, "runtime_project_kanban board_id=%d project=%s task_ref_prefix=%s\n", context.KanbanIdentity.BoardID, context.KanbanIdentity.Project, context.KanbanIdentity.TaskRefPrefix)
	}
	fmt.Fprintf(stdout, "runtime_package=%s\n", effectiveConfig.PackagePath)
	fmt.Fprintf(stdout, "compose_project=%s\n", effectiveConfig.ComposeProject)
	fmt.Fprintf(stdout, "kanban_mode=%s\n", kanbanMode(effectiveConfig))
	fmt.Fprintf(stdout, "kanban_url=%s\n", kanbanPublicURL(effectiveConfig))
	var pauseSummary runtimeSchedulerPauseInfo
	ensurePauseSummary := func() error {
		if pauseSummary.Line != "" {
			return nil
		}
		return withComposeEnv(effectiveConfig, func() error {
			pauseSummary = runtimeSchedulerPauseSummary(effectiveConfig, runner)
			return nil
		})
	}
	pid, err := readSchedulerPID(paths.PIDFile)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			fmt.Fprintf(stdout, "runtime_scheduler_status=stopped pid_file=%s log=%s\n", paths.PIDFile, paths.LogFile)
		} else {
			return err
		}
	} else if schedulerProcessRunning(pid, paths.CommandFile, runner) {
		fmt.Fprintf(stdout, "runtime_scheduler_status=running pid=%d pid_file=%s log=%s\n", pid, paths.PIDFile, paths.LogFile)
	} else {
		if err := ensurePauseSummary(); err != nil {
			return err
		}
		if pauseSummary.Available && pauseSummary.Paused {
			fmt.Fprintf(stdout, "runtime_scheduler_status=stopped stale_pid=%d pid_file=%s log=%s note=scheduler_stopped_stale_pid_harmless cleanup_hint=remove_stale_pid_file\n", pid, paths.PIDFile, paths.LogFile)
		} else {
			fmt.Fprintf(stdout, "runtime_scheduler_status=stale pid=%d pid_file=%s log=%s\n", pid, paths.PIDFile, paths.LogFile)
		}
	}
	return withComposeEnv(effectiveConfig, func() error {
		if pauseSummary.Line == "" {
			pauseSummary = runtimeSchedulerPauseSummary(effectiveConfig, runner)
		}
		fmt.Fprintln(stdout, pauseSummary.Line)
		printRuntimeServiceStatus(effectiveConfig, runner, stdout)
		printRuntimeImageStatus(&effectiveConfig, runner, stdout)
		printRuntimeClaimSummary(effectiveConfig, runner, stdout)
		printLatestRuntimeSummary(effectiveConfig, runner, stdout)
		return nil
	})
}

func runtimeSchedulerStateCommand(config runtimeInstanceConfig, runner commandRunner, command string) error {
	plan, err := buildRuntimeRunOncePlan(config, runtimeRunOnceOverrides{}, "")
	if err != nil {
		return err
	}
	_, err = dockerComposeExecOutput(config, plan, runner, "a3", command, "--storage-backend", "json", "--storage-dir", plan.StorageDir)
	return err
}

type runtimeSchedulerPauseInfo struct {
	Line      string
	Paused    bool
	Available bool
}

func runtimeSchedulerPauseSummary(config runtimeInstanceConfig, runner commandRunner) runtimeSchedulerPauseInfo {
	plan, err := buildRuntimeRunOncePlan(config, runtimeRunOnceOverrides{}, "")
	if err != nil {
		return runtimeSchedulerPauseInfo{
			Line: "runtime_scheduler_pause status=unavailable reason=" + singleLine(err.Error()),
		}
	}
	output, err := dockerComposeExecOutput(config, plan, runner, "a3", "show-scheduler-state", "--storage-backend", "json", "--storage-dir", plan.StorageDir)
	if err != nil {
		return runtimeSchedulerPauseInfo{
			Line: "runtime_scheduler_pause status=unavailable reason=" + singleLine(err.Error()),
		}
	}
	summary := strings.TrimSpace(string(output))
	if summary == "" {
		return runtimeSchedulerPauseInfo{
			Line: "runtime_scheduler_pause status=unavailable reason=empty",
		}
	}
	paused := false
	if strings.HasPrefix(summary, "scheduler ") {
		paused = strings.Contains(" "+summary+" ", " paused=true ")
		summary = "runtime_" + summary
	}
	return runtimeSchedulerPauseInfo{
		Line:      sanitizePublicCommand(summary),
		Paused:    paused,
		Available: true,
	}
}
