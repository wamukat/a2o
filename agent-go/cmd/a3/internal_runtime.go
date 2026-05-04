package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const packagedKanbanCLIPath = "/opt/a2o/share/tools/kanban/cli.py"
const packagedKanbanBootstrapPath = "/opt/a2o/share/tools/kanban/bootstrap_kanbalone.py"

func runRuntime(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "missing runtime subcommand")
		printUsage(stderr)
		return 2
	}
	if isHelpArg(args[0]) {
		printUsage(stdout)
		return 0
	}

	switch args[0] {
	case "up":
		if err := runRuntimeUp(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "down":
		if err := runRuntimeDown(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "resume":
		if err := runRuntimeResume(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "pause":
		if err := runRuntimePause(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "status":
		if err := runRuntimeStatus(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "image-digest":
		if err := runRuntimeImageDigest(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "doctor":
		if err := runRuntimeDoctor(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "describe-task":
		if err := runRuntimeDescribeTask(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "reset-task":
		if err := runRuntimeResetTask(args[1:], stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "force-stop-task":
		if err := runRuntimeForceStop("task", args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "force-stop-run":
		if err := runRuntimeForceStop("run", args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "watch-summary":
		if err := runRuntimeWatchSummary(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "decomposition":
		if err := runRuntimeDecomposition(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "skill-feedback":
		if err := runRuntimeSkillFeedback(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "metrics":
		if err := runRuntimeMetrics(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "logs":
		if err := runRuntimeLogs(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "show-artifact":
		if err := runRuntimeShowArtifact(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "clear-logs":
		if err := runRuntimeClearLogs(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "run-once":
		if err := runRuntimeRunOnce(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "loop":
		if err := runRuntimeLoop(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "start", "stop":
		printRemovedRuntimeCommandError(stderr, args[0])
		return 2
	default:
		fmt.Fprintf(stderr, "unknown runtime subcommand: %s\n", args[0])
		printUsage(stderr)
		return 2
	}
}

func printRemovedRuntimeCommandError(stderr io.Writer, command string) {
	replacement := map[string]string{
		"start": "a2o runtime resume",
		"stop":  "a2o runtime pause",
	}[command]
	fmt.Fprintf(stderr, "removed runtime subcommand: %s\n", command)
	fmt.Fprintln(stderr, "reason: this compatibility alias was removed to keep the runtime lifecycle contract explicit.")
	fmt.Fprintf(stderr, "migration_required=true replacement_command=%q\n", replacement)
	fmt.Fprintf(stderr, "use %q instead of %q.\n", replacement, "a2o runtime "+command)
}

type runtimeSchedulerPaths struct {
	Dir         string
	PIDFile     string
	CommandFile string
	LogFile     string
}

func schedulerPaths(config runtimeInstanceConfig) runtimeSchedulerPaths {
	dir := filepath.Join(config.WorkspaceRoot, ".work", "a2o-runtime")
	if config.MultiProjectMode {
		config.ProjectKey = effectiveRuntimeProjectKey(config)
		dir = filepath.Join(config.WorkspaceRoot, ".work", "a2o", "projects", safeProjectKeyComponent(config.ProjectKey), "scheduler")
	}
	return runtimeSchedulerPaths{
		Dir:         dir,
		PIDFile:     filepath.Join(dir, "scheduler.pid"),
		CommandFile: filepath.Join(dir, "scheduler.command"),
		LogFile:     filepath.Join(dir, "scheduler.log"),
	}
}

func printLatestRuntimeSummary(config runtimeInstanceConfig, runner commandRunner, stdout io.Writer) {
	plan, err := buildRuntimeDescribeTaskPlan(config)
	if err != nil {
		fmt.Fprintf(stdout, "runtime_latest_run status=unavailable reason=%s\n", singleLine(err.Error()))
		return
	}
	runHistoryPath := path.Join(plan.StorageDir, "runs.json")
	existsOutput, err := dockerComposeExecOutput(config, plan, runner, "sh", "-c", "if test -f \"$1\"; then echo present; else echo missing; fi", "sh", runHistoryPath)
	if err != nil {
		fmt.Fprintf(stdout, "runtime_latest_run status=unavailable reason=%s\n", singleLine(err.Error()))
		return
	}
	if strings.TrimSpace(string(existsOutput)) != "present" {
		fmt.Fprintln(stdout, "runtime_latest_run status=no_runs reason=history_empty")
		return
	}
	script := "records = JSON.parse(File.read(ARGV.fetch(0))); run = records.values.last; if run then outcome = run['terminal_outcome']; state = outcome ? 'terminal' : 'active'; puts \"runtime_latest_run run_ref=#{run['ref']} task_ref=#{run['task_ref']} phase=#{run['phase'] || '-'} state=#{state} outcome=#{outcome || '-'}\" end"
	output, err := dockerComposeExecOutput(config, plan, runner, "ruby", "-rjson", "-e", script, runHistoryPath)
	if err != nil {
		fmt.Fprintf(stdout, "runtime_latest_run status=unavailable reason=%s\n", singleLine(err.Error()))
		return
	}
	summary := strings.TrimSpace(string(output))
	if summary == "" {
		fmt.Fprintln(stdout, "runtime_latest_run status=no_runs reason=history_empty")
		return
	}
	fmt.Fprintln(stdout, sanitizePublicCommand(summary))
}

func printRuntimeClaimSummary(config runtimeInstanceConfig, runner commandRunner, stdout io.Writer) {
	plan, err := buildRuntimeDescribeTaskPlan(config)
	if err != nil {
		fmt.Fprintf(stdout, "runtime_active_claims status=unavailable reason=%s\n", singleLine(err.Error()))
		return
	}
	output, err := dockerComposeExecOutput(config, plan, runner, "a3", "show-state", "--storage-backend", "json", "--storage-dir", plan.StorageDir)
	if err != nil {
		fmt.Fprintf(stdout, "runtime_active_claims status=unavailable reason=%s\n", singleLine(err.Error()))
		return
	}
	for _, line := range strings.Split(strings.TrimSpace(string(output)), "\n") {
		line = strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(line, "active_claims="):
			fmt.Fprintf(stdout, "runtime_%s\n", sanitizePublicCommand(line))
		case strings.HasPrefix(line, "claim "):
			fmt.Fprintf(stdout, "runtime_%s\n", sanitizePublicCommand(line))
		}
	}
}

func pathsConfig(config *runtimeInstanceConfig) runtimeInstanceConfig {
	return applyAgentInstallOverrides(*config, "", "", "")
}

func readRunningScheduler(pidFile string, runner commandRunner) (int, bool, error) {
	pid, err := readSchedulerPID(pidFile)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return 0, false, nil
		}
		return 0, false, err
	}
	return pid, schedulerProcessRunning(pid, filepath.Join(filepath.Dir(pidFile), "scheduler.command"), runner), nil
}

func schedulerProcessRunning(pid int, commandFile string, runner commandRunner) bool {
	if !runner.ProcessRunning(pid) {
		return false
	}
	expectedCommand, err := readSchedulerExpectedCommand(commandFile)
	if err != nil {
		return false
	}
	command := runner.ProcessCommand(pid)
	return command == expectedCommand
}

func schedulerExpectedCommand(executable string, args []string) string {
	return strings.Join(append([]string{executable}, args...), " ")
}

func readSchedulerExpectedCommand(path string) (string, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	command := strings.TrimSpace(string(body))
	if command == "" {
		return "", fmt.Errorf("scheduler command file is empty: %s", path)
	}
	return command, nil
}

func readSchedulerPID(path string) (int, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	pidText := strings.TrimSpace(string(body))
	if pidText == "" {
		return 0, fmt.Errorf("scheduler pid file is empty: %s", path)
	}
	pid, err := parsePositiveInt(pidText, "scheduler pid")
	if err != nil {
		return 0, fmt.Errorf("invalid scheduler pid file %s: %w", path, err)
	}
	return pid, nil
}

func runRuntimeUp(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime up", flag.ContinueOnError)
	flags.SetOutput(stderr)
	build := flags.Bool("build", false, "build the runtime image before starting services")
	pull := flags.Bool("pull", false, "pull the configured runtime image before starting services")
	projectKey := flags.String("project", "", "runtime project key")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	context, _, err := loadProjectRuntimeContextForCommand(*projectKey, true)
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(context.Config, "", "", "")
	composePrefix := composeArgs(effectiveConfig)
	return withComposeEnv(effectiveConfig, func() error {
		if *pull && !*build {
			if _, err := runExternal(runner, "docker", append(composePrefix, "pull", effectiveConfig.RuntimeService)...); err != nil {
				return err
			}
		}
		if *build {
			if _, err := runExternal(runner, "docker", append(composePrefix, "build", effectiveConfig.RuntimeService)...); err != nil {
				return err
			}
		}
		if err := cleanupLegacyRuntimeServiceOrphans(effectiveConfig, runner, stdout); err != nil {
			return err
		}
		services := []string{effectiveConfig.RuntimeService}
		if !isExternalKanban(effectiveConfig) {
			if _, err := guardRemovedSoloBoardKanbanData(effectiveConfig, runner); err != nil {
				return err
			}
			services = append(services, "kanbalone")
		}
		if _, err := runExternal(runner, "docker", append(composePrefix, append([]string{"up", "-d"}, services...)...)...); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "runtime_up compose_project=%s project_key=%s package=%s kanban_mode=%s\n", effectiveConfig.ComposeProject, context.ProjectKey, effectiveConfig.PackagePath, kanbanMode(effectiveConfig))
		return nil
	})
}

func cleanupLegacyRuntimeServiceOrphans(config runtimeInstanceConfig, runner commandRunner, stdout io.Writer) error {
	if strings.TrimSpace(config.RuntimeService) != "a2o-runtime" {
		return nil
	}
	composeProject := strings.TrimSpace(config.ComposeProject)
	if composeProject == "" {
		return nil
	}
	output, err := runExternal(
		runner,
		"docker",
		"ps",
		"-a",
		"--filter",
		"label=com.docker.compose.project="+composeProject,
		"--filter",
		"label=com.docker.compose.service=a3-runtime",
		"--format",
		"{{.ID}}",
	)
	if err != nil {
		return fmt.Errorf("detect obsolete runtime service containers for compose_project=%s: %w", composeProject, err)
	}
	containerIDs := nonEmptyLines(output)
	if len(containerIDs) == 0 {
		return nil
	}
	if _, err := runExternal(runner, "docker", append([]string{"rm", "-f"}, containerIDs...)...); err != nil {
		remediation := shellJoin(append([]string{"docker", "rm", "-f"}, containerIDs...))
		return fmt.Errorf("remove obsolete runtime service containers for compose_project=%s: %w\nsafe_remediation=%s", composeProject, err, remediation)
	}
	fmt.Fprintf(stdout, "runtime_orphan_cleanup compose_project=%s service=legacy-runtime containers=%s action=removed\n", composeProject, strings.Join(containerIDs, ","))
	return nil
}

func runRuntimeDoctor(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime doctor", flag.ContinueOnError)
	flags.SetOutput(stderr)
	projectKey := flags.String("project", "", "runtime project key")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	context, configPath, err := loadProjectRuntimeContextForCommand(*projectKey, true)
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(context.Config, "", "", "")
	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", publicInstanceConfigPath(configPath))
	fmt.Fprintf(stdout, "runtime_project_key=%s\n", context.ProjectKey)
	fmt.Fprintf(stdout, "package=%s\n", effectiveConfig.PackagePath)
	fmt.Fprintf(stdout, "compose_project=%s\n", effectiveConfig.ComposeProject)
	fmt.Fprintf(stdout, "kanban_mode=%s\n", kanbanMode(effectiveConfig))
	for _, check := range []struct {
		name    string
		service string
	}{
		{name: "runtime_container", service: effectiveConfig.RuntimeService},
		{name: "kanban_service", service: "kanbalone"},
	} {
		if check.name == "kanban_service" && isExternalKanban(effectiveConfig) {
			if err := checkExternalKanbanHealth(kanbanPublicURL(effectiveConfig)); err != nil {
				return err
			}
			fmt.Fprintf(stdout, "runtime_doctor_check name=kanban_external status=ok url=%s runtime_url=%s\n", kanbanPublicURL(effectiveConfig), kanbanRuntimeURL(effectiveConfig))
			continue
		}
		output, err := runExternal(runner, "docker", append(composeArgs(effectiveConfig), "ps", "--status", "running", "-q", check.service)...)
		if err != nil {
			return err
		}
		containerID := strings.TrimSpace(string(output))
		if containerID == "" {
			fmt.Fprintf(stdout, "runtime_doctor_check name=%s status=blocked action=run a2o runtime up%s\n", check.name, runtimeProjectCommandArg(context.ProjectKey, effectiveConfig.MultiProjectMode))
			continue
		}
		fmt.Fprintf(stdout, "runtime_doctor_check name=%s status=ok container=%s\n", check.name, containerID)
	}
	return nil
}

func runRuntimeDown(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime down", flag.ContinueOnError)
	flags.SetOutput(stderr)
	projectKey := flags.String("project", "", "runtime project key")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	context, _, err := loadProjectRuntimeContextForCommand(*projectKey, true)
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(context.Config, "", "", "")
	if _, err := runExternal(runner, "docker", append(composeArgs(effectiveConfig), "down")...); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "runtime_down compose_project=%s project_key=%s\n", effectiveConfig.ComposeProject, context.ProjectKey)
	return nil
}

func runRuntimeCommandPlan(args []string, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime command-plan", flag.ContinueOnError)
	flags.SetOutput(stderr)
	projectKey := flags.String("project", "", "runtime project key")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	context, configPath, err := loadProjectRuntimeContextForCommand(*projectKey, true)
	if err != nil {
		return err
	}
	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", publicInstanceConfigPath(configPath))
	fmt.Fprintf(stdout, "runtime_project_key=%s\n", context.ProjectKey)
	fmt.Fprintln(stdout, "kanban_up=a2o kanban up")
	fmt.Fprintln(stdout, "kanban_doctor=a2o kanban doctor")
	fmt.Fprintf(stdout, "kanban_url=%s\n", kanbanPublicURL(context.Config))
	fmt.Fprintf(stdout, "runtime_up=a2o runtime up%s\n", runtimeProjectCommandArg(context.ProjectKey, context.Config.MultiProjectMode))
	fmt.Fprintln(stdout, "agent_install=a2o agent install")
	return nil
}

func runRuntimeDescribeTask(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime describe-task", flag.ContinueOnError)
	flags.SetOutput(stderr)
	projectKey := flags.String("project", "", "runtime project key")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 1 {
		return fmt.Errorf("usage: a2o runtime describe-task TASK_REF")
	}
	taskRef := strings.TrimSpace(flags.Arg(0))
	if taskRef == "" {
		return fmt.Errorf("task ref is required")
	}
	resolvedProject, resolvedTaskRef, err := resolveRuntimeProjectTaskRef(*projectKey, taskRef)
	if err != nil {
		return err
	}
	taskRef = resolvedTaskRef

	context, configPath, err := loadProjectRuntimeContextForCommand(resolvedProject, true)
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(context.Config, "", "", "")
	return withComposeEnv(effectiveConfig, func() error {
		plan, err := buildRuntimeDescribeTaskPlan(effectiveConfig)
		if err != nil {
			return err
		}
		fmt.Fprintf(stdout, "describe_task task_ref=%s\n", taskRef)
		fmt.Fprintf(stdout, "runtime_instance_config=%s\n", publicInstanceConfigPath(configPath))
		fmt.Fprintf(stdout, "runtime_project_key=%s\n", context.ProjectKey)
		fmt.Fprintf(stdout, "package=%s\n", effectiveConfig.PackagePath)
		fmt.Fprintf(stdout, "compose_project=%s\n", effectiveConfig.ComposeProject)
		fmt.Fprintf(stdout, "kanban_project=%s kanban_url=%s\n", plan.KanbanProject, kanbanPublicURL(effectiveConfig))
		fmt.Fprintf(stdout, "runtime_storage=internal-managed project_config=%s surface_source=project-package\n", plan.ManifestPath)
		projectArg := runtimeProjectCommandArg(context.ProjectKey, effectiveConfig.MultiProjectMode)
		fmt.Fprintf(stdout, "operator_next=a2o runtime describe-task%s %s\n", projectArg, taskRef)

		runRef := ""
		taskOutput, err := runtimeDescribeSectionOutput(effectiveConfig, plan, runner, "task", "a3", "show-task", "--storage-backend", "json", "--storage-dir", plan.StorageDir, taskRef)
		if err != nil {
			fmt.Fprintf(stdout, "describe_section name=task status=blocked action=run a2o runtime run-once%s or verify task ref detail=%s\n", projectArg, singleLine(err.Error()))
		} else {
			printDescribeSection(stdout, "task", taskOutput)
			runRef = parseOutputValue(taskOutput, "current_run")
		}
		if runRef == "" {
			latestRunRef, latestErr := latestRuntimeRunRef(effectiveConfig, plan, runner, taskRef)
			if latestErr != nil {
				fmt.Fprintf(stdout, "describe_section name=run_ref status=blocked action=inspect runs store detail=%s\n", singleLine(latestErr.Error()))
			} else if latestRunRef != "" {
				runRef = latestRunRef
				fmt.Fprintf(stdout, "describe_section name=run_ref status=resolved source=latest_run_store run_ref=%s\n", runRef)
			}
		}
		if runRef == "" {
			fmt.Fprintln(stdout, "describe_section name=run status=skipped reason=no_run_for_task")
		} else {
			runOutput, runErr := runtimeDescribeSectionOutput(effectiveConfig, plan, runner, "run", runtimeInspectionArgs("a3", "show-run", "--storage-backend", "json", "--storage-dir", plan.StorageDir, "--preset-dir", plan.PresetDir, runRef, plan.ManifestPath)...)
			if runErr != nil {
				fmt.Fprintf(stdout, "describe_section name=run status=blocked run_ref=%s action=inspect runtime log detail=%s\n", runRef, singleLine(runErr.Error()))
			} else {
				printDescribeSection(stdout, "run", runOutput)
			}
		}

		printDescribeKanbanSection(effectiveConfig, plan, runner, stdout, taskRef)
		fmt.Fprintf(stdout, "runtime_logs runtime=%s server=%s host_agent=%s exit_file=%s\n", plan.RuntimeLog, plan.ServerLog, plan.HostAgentLog, plan.RuntimeExitFile)
		fmt.Fprintf(stdout, "operator_logs runtime_log=%s server_log=%s host_agent_log=%s\n",
			plan.RuntimeLog,
			plan.ServerLog,
			plan.HostAgentLog,
		)
		return nil
	})
}

func runRuntimeWatchSummary(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime watch-summary", flag.ContinueOnError)
	flags.SetOutput(stderr)
	details := flags.Bool("details", false, "show per-task waiting and review detail lines")
	projectKey := flags.String("project", "", "runtime project key")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	context, _, err := loadProjectRuntimeContextForCommand(*projectKey, false)
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(context.Config, "", "", "")
	paths := schedulerPaths(effectiveConfig)
	return withComposeEnv(effectiveConfig, func() error {
		plan, err := buildRuntimeDescribeTaskPlan(effectiveConfig)
		if err != nil {
			return err
		}
		output, err := runtimeDescribeSectionOutput(effectiveConfig, plan, runner, "watch_summary", runtimeWatchSummaryArgs(plan, *details)...)
		if err != nil {
			return err
		}
		if strings.TrimSpace(output) == "" {
			return nil
		}
		fmt.Fprintln(stdout, overlaySchedulerWatchSummaryState(output, paths, runner))
		return nil
	})
}

func runRuntimeSkillFeedback(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	if len(args) == 0 || (args[0] != "list" && args[0] != "propose") {
		return fmt.Errorf("usage: a2o runtime skill-feedback (list|propose)")
	}
	subcommand := args[0]
	flags := flag.NewFlagSet("a2o runtime skill-feedback "+subcommand, flag.ContinueOnError)
	flags.SetOutput(stderr)
	projectKey := flags.String("project", "", "runtime project key")
	state := flags.String("state", "", "filter by feedback lifecycle state")
	target := flags.String("target", "", "filter by feedback target")
	group := false
	format := "ticket"
	if subcommand == "list" {
		flags.BoolVar(&group, "group", false, "group duplicate feedback entries")
	}
	if subcommand == "propose" {
		flags.StringVar(&format, "format", "ticket", "proposal format: ticket or patch")
	}
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	context, _, err := loadProjectRuntimeContextForCommand(*projectKey, true)
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(context.Config, "", "", "")
	return withComposeEnv(effectiveConfig, func() error {
		plan, err := buildRuntimeDescribeTaskPlan(effectiveConfig)
		if err != nil {
			return err
		}
		runtimeArgs := []string{"a3", "skill-feedback-" + subcommand, "--storage-backend", "json", "--storage-dir", plan.StorageDir}
		if *state != "" {
			runtimeArgs = append(runtimeArgs, "--state", *state)
		}
		if *target != "" {
			runtimeArgs = append(runtimeArgs, "--target", *target)
		}
		if subcommand == "list" && group {
			runtimeArgs = append(runtimeArgs, "--group")
		}
		if subcommand == "propose" {
			runtimeArgs = append(runtimeArgs, "--format", format)
		}
		output, err := runtimeDescribeSectionOutput(effectiveConfig, plan, runner, "skill_feedback", runtimeArgs...)
		if err != nil {
			return err
		}
		if strings.TrimSpace(output) != "" {
			fmt.Fprint(stdout, output)
			if !strings.HasSuffix(output, "\n") {
				fmt.Fprintln(stdout)
			}
		}
		return nil
	})
}

func runRuntimeMetrics(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	if len(args) == 0 || (args[0] != "list" && args[0] != "summary" && args[0] != "trends") {
		return fmt.Errorf("usage: a2o runtime metrics (list|summary|trends)")
	}
	subcommand := args[0]
	flags := flag.NewFlagSet("a2o runtime metrics "+subcommand, flag.ContinueOnError)
	flags.SetOutput(stderr)
	projectKey := flags.String("project", "", "runtime project key")
	format := "json"
	groupBy := "task"
	if subcommand == "list" {
		flags.StringVar(&format, "format", "json", "output format: json or csv")
	}
	if subcommand == "summary" {
		format = "text"
		flags.StringVar(&format, "format", "text", "output format: text or json")
		flags.StringVar(&groupBy, "group-by", "task", "summary grouping: task or parent")
	}
	if subcommand == "trends" {
		format = "text"
		groupBy = "all"
		flags.StringVar(&format, "format", "text", "output format: text or json")
		flags.StringVar(&groupBy, "group-by", "all", "trend grouping: all, task, or parent")
	}
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	context, _, err := loadProjectRuntimeContextForCommand(*projectKey, true)
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(context.Config, "", "", "")
	return withComposeEnv(effectiveConfig, func() error {
		plan, err := buildRuntimeDescribeTaskPlan(effectiveConfig)
		if err != nil {
			return err
		}
		runtimeArgs := []string{"a3", "metrics", subcommand, "--storage-backend", "json", "--storage-dir", plan.StorageDir, "--format", format}
		if subcommand == "summary" || subcommand == "trends" {
			runtimeArgs = append(runtimeArgs, "--group-by", groupBy)
		}
		output, err := runtimeDescribeSectionOutput(effectiveConfig, plan, runner, "metrics", runtimeArgs...)
		if err != nil {
			return err
		}
		if strings.TrimSpace(output) != "" {
			fmt.Fprint(stdout, output)
			if !strings.HasSuffix(output, "\n") {
				fmt.Fprintln(stdout)
			}
		}
		return nil
	})
}

func overlaySchedulerWatchSummaryState(output string, paths runtimeSchedulerPaths, runner commandRunner) string {
	lines := strings.Split(output, "\n")
	if len(lines) == 0 {
		return output
	}
	if !strings.HasPrefix(lines[0], "Scheduler: ") {
		return output
	}
	if strings.HasPrefix(lines[0], "Scheduler: paused") {
		return output
	}
	pid, running, err := readRunningScheduler(paths.PIDFile, runner)
	if err != nil {
		return output
	}
	if pid == 0 {
		lines[0] = "Scheduler: stopped"
		return strings.Join(lines, "\n")
	}
	if !running {
		lines[0] = "Scheduler: stale"
		return strings.Join(lines, "\n")
	}
	return output
}

func runRuntimeRunOnce(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime run-once", flag.ContinueOnError)
	flags.SetOutput(stderr)
	maxSteps := flags.String("max-steps", "", "maximum runtime steps for this cycle")
	agentAttempts := flags.String("agent-attempts", "", "maximum host agent attempts for this cycle")
	agentPollInterval := flags.String("agent-poll-interval", "", "idle duration between host agent polls for this cycle")
	agentControlPlaneConnectTimeout := flags.String("agent-control-plane-connect-timeout", "", "TCP connect timeout for host agent control plane requests for this cycle")
	agentControlPlaneRequestTimeout := flags.String("agent-control-plane-request-timeout", "", "per-request timeout for host agent control plane requests for this cycle")
	agentControlPlaneRetries := flags.String("agent-control-plane-retries", "", "retry count for transient host agent control plane request failures for this cycle")
	agentControlPlaneRetryDelay := flags.String("agent-control-plane-retry-delay", "", "delay between transient host agent control plane retries for this cycle")
	projectConfig := flags.String("project-config", "", "explicit project config file, for example project-test.yaml")
	projectKey := flags.String("project", "", "runtime project key")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	context, configPath, err := loadProjectRuntimeContextForCommand(*projectKey, true)
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(context.Config, "", "", "")
	overrides := runtimeRunOnceOverrides{
		MaxSteps:                        *maxSteps,
		AgentAttempts:                   *agentAttempts,
		AgentPollInterval:               *agentPollInterval,
		AgentControlPlaneConnectTimeout: *agentControlPlaneConnectTimeout,
		AgentControlPlaneRequestTimeout: *agentControlPlaneRequestTimeout,
		AgentControlPlaneRetries:        *agentControlPlaneRetries,
		AgentControlPlaneRetryDelay:     *agentControlPlaneRetryDelay,
	}

	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", publicInstanceConfigPath(configPath))
	fmt.Fprintf(stdout, "runtime_project_key=%s\n", context.ProjectKey)
	fmt.Fprintf(stdout, "describe_task=a2o runtime describe-task%s <task-ref>\n", runtimeProjectCommandArg(context.ProjectKey, effectiveConfig.MultiProjectMode))
	return withRuntimeRunOnceEnv(effectiveConfig, overrides.MaxSteps, overrides.AgentAttempts, func() error {
		return runGenericRuntimeRunOnce(effectiveConfig, overrides, *projectConfig, runner, stdout)
	})
}

type runtimeRunOncePlan struct {
	ProjectKey                                string
	MultiProjectMode                          bool
	ComposePrefix                             []string
	MaxSteps                                  string
	AgentAttempts                             int
	AgentIdleLimit                            int
	AgentPollInterval                         time.Duration
	AgentControlPlaneConnectTimeout           time.Duration
	AgentControlPlaneRequestTimeout           time.Duration
	AgentControlPlaneRetryCount               int
	AgentControlPlaneRetryDelay               time.Duration
	AgentPort                                 string
	AgentInternalPort                         string
	StorageDir                                string
	HostRootDir                               string
	HostRoot                                  string
	WorkspaceRoot                             string
	HostAgentBin                              string
	HostAgentSource                           string
	HostAgentTarget                           string
	HostAgentLog                              string
	LiveLogRoot                               string
	AIRawLogRoot                              string
	LauncherConfigPath                        string
	LauncherConfig                            map[string]any
	ServerLog                                 string
	RuntimeLog                                string
	RuntimeExitFile                           string
	RuntimePIDFile                            string
	ServerPIDFile                             string
	PresetDir                                 string
	ManifestPath                              string
	SoloBoardInternalURL                      string
	LiveRef                                   string
	AgentEnv                                  []string
	AgentSourcePaths                          []string
	AgentRequiredBins                         []string
	AgentSourceAliases                        []string
	AgentPublishCommitPreflightNativeGitHooks string
	AgentPublishCommitPreflightCommands       []string
	KanbanProject                             string
	KanbanStatus                              string
	KanbanRepoLabels                          []string
	RepoSources                               []string
	LocalSourceAliases                        []string
	WorkerCommand                             string
	WorkerArgs                                []string
	JobTimeoutSeconds                         string
	BranchNamespace                           string
}

type runtimeRunOnceOverrides struct {
	MaxSteps                        string
	AgentAttempts                   string
	AgentPollInterval               string
	AgentControlPlaneConnectTimeout string
	AgentControlPlaneRequestTimeout string
	AgentControlPlaneRetries        string
	AgentControlPlaneRetryDelay     string
}

func runGenericRuntimeRunOnce(config runtimeInstanceConfig, overrides runtimeRunOnceOverrides, projectConfig string, runner commandRunner, stdout io.Writer) error {
	plan, err := buildRuntimeRunOncePlan(config, overrides, projectConfig)
	if err != nil {
		return err
	}
	return withComposeEnv(config, func() error {
		if err := cleanupLegacyRuntimeServiceOrphans(config, runner, stdout); err != nil {
			return err
		}
		services := []string{config.RuntimeService}
		if !isExternalKanban(config) {
			if _, err := guardRemovedSoloBoardKanbanData(config, runner); err != nil {
				return err
			}
			services = append(services, "kanbalone")
		}
		if _, err := runExternal(runner, "docker", append(plan.ComposePrefix, append([]string{"up", "-d"}, services...)...)...); err != nil {
			return err
		}
		if err := repairRuntimeRuns(config, plan, runner, stdout, "startup"); err != nil {
			return err
		}
		if err := archiveRuntimeStateIfRequested(config, plan, runner, stdout); err != nil {
			return err
		}
		if err := cleanupRuntimeProcesses(config, plan, runner); err != nil {
			return err
		}
		if err := ensureRuntimeLauncherConfig(plan, stdout); err != nil {
			return err
		}
		handledDecomposition, err := runAutomaticRuntimeDecompositionIfReady(config, plan, runner, stdout)
		if err != nil {
			return err
		}
		if handledDecomposition {
			return nil
		}
		fmt.Fprintf(stdout, "kanban_run_once=generic\n")
		if err := ensureRuntimeHostAgent(config, plan, runner, stdout); err != nil {
			return err
		}
		if err := startRuntimeAgentServer(config, plan, runner, stdout); err != nil {
			return err
		}
		if err := waitForRuntimeControlPlane(plan, runner); err != nil {
			return err
		}
		if err := startRuntimeExecuteUntilIdle(config, plan, runner, stdout); err != nil {
			return err
		}
		if err := runHostAgentLoop(config, plan, runner, stdout); err != nil {
			_ = cleanupRuntimeProcesses(config, plan, runner)
			_ = repairRuntimeRuns(config, plan, runner, stdout, "agent_attempt_budget_exhausted")
			return err
		}
		runtimeExit, err := readRuntimeExit(config, plan, runner)
		if err != nil {
			return err
		}
		fmt.Fprintf(stdout, "kanban_run_once_finished exit=%s\n", runtimeExit)
		if runtimeExit != "0" {
			_ = printRuntimeDiagnostics(config, plan, runner, stdout)
			return fmt.Errorf("runtime run-once failed with exit=%s", runtimeExit)
		}
		return printRuntimeSuccessTail(config, plan, runner, stdout)
	})
}

func ensureRuntimeLauncherConfig(plan runtimeRunOncePlan, stdout io.Writer) error {
	if len(plan.LauncherConfig) == 0 {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(plan.LauncherConfigPath), 0o755); err != nil {
		return fmt.Errorf("create worker launcher config directory: %w", err)
	}
	payload := map[string]any{"executor": plan.LauncherConfig}
	body, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return fmt.Errorf("encode worker launcher config: %w", err)
	}
	if err := os.WriteFile(plan.LauncherConfigPath, append(body, '\n'), 0o600); err != nil {
		return fmt.Errorf("write worker launcher config: %w", err)
	}
	fmt.Fprintf(stdout, "runtime_worker_launcher_config=%s\n", plan.LauncherConfigPath)
	return nil
}

func buildRuntimeRunOncePlan(config runtimeInstanceConfig, overrides runtimeRunOnceOverrides, projectConfig string) (runtimeRunOncePlan, error) {
	if err := validateRuntimeProjectSideEffectScope(config); err != nil {
		return runtimeRunOncePlan{}, err
	}
	if config.MultiProjectMode {
		config.ProjectKey = effectiveRuntimeProjectKey(config)
	}
	hostRootDir := envDefaultCompat("A2O_RUNTIME_RUN_ONCE_HOST_ROOT_DIR", "A3_RUNTIME_RUN_ONCE_HOST_ROOT_DIR", envDefaultCompat("A2O_RUNTIME_SCHEDULER_HOST_ROOT_DIR", "A3_RUNTIME_SCHEDULER_HOST_ROOT_DIR", config.WorkspaceRoot))
	if strings.TrimSpace(hostRootDir) == "" {
		hostRootDir = "."
	}
	referencePackagePath := envDefaultCompat("A2O_RUNTIME_RUN_ONCE_REFERENCE_PACKAGE", "A3_RUNTIME_RUN_ONCE_REFERENCE_PACKAGE", envDefaultCompat("A2O_RUNTIME_SCHEDULER_REFERENCE_PACKAGE", "A3_RUNTIME_SCHEDULER_REFERENCE_PACKAGE", config.PackagePath))
	if strings.TrimSpace(referencePackagePath) == "" {
		return runtimeRunOncePlan{}, errors.New("runtime package path is empty; run `a2o project bootstrap` from a workspace with ./a2o-project or ./project-package first")
	}
	projectConfigPath := envDefaultValue(projectConfig, envDefaultCompat("A2O_RUNTIME_RUN_ONCE_PROJECT_CONFIG", "A3_RUNTIME_RUN_ONCE_PROJECT_CONFIG", envDefaultCompat("A2O_RUNTIME_SCHEDULER_PROJECT_CONFIG", "A3_RUNTIME_SCHEDULER_PROJECT_CONFIG", "")))
	if strings.TrimSpace(projectConfigPath) == "" {
		projectConfigPath = filepath.Join(referencePackagePath, "project.yaml")
	} else if !filepath.IsAbs(projectConfigPath) {
		projectConfigPath = filepath.Join(referencePackagePath, projectConfigPath)
	}
	packageConfig, err := loadProjectPackageConfigFile(projectConfigPath)
	if err != nil {
		return runtimeRunOncePlan{}, err
	}
	effectivePackagePath := filepath.Dir(projectConfigPath)
	hostRoot := envDefaultCompat("A2O_RUNTIME_RUN_ONCE_HOST_ROOT", "A3_RUNTIME_RUN_ONCE_HOST_ROOT", envDefaultCompat("A2O_RUNTIME_SCHEDULER_HOST_ROOT", "A3_RUNTIME_SCHEDULER_HOST_ROOT", runtimeProjectHostRoot(hostRootDir, config)))
	defaultWorkspaceRoot := filepath.Join(hostRoot, "workspaces")
	if strings.TrimSpace(packageConfig.AgentWorkspaceRoot) != "" {
		defaultWorkspaceRoot = runtimeProjectAgentWorkspaceRoot(hostRootDir, config, packageConfig.AgentWorkspaceRoot)
	}
	workspaceRoot := envDefaultCompat("A2O_RUNTIME_RUN_ONCE_AGENT_WORKSPACE_ROOT", "A3_RUNTIME_RUN_ONCE_AGENT_WORKSPACE_ROOT", envDefaultCompat("A2O_RUNTIME_SCHEDULER_AGENT_WORKSPACE_ROOT", "A3_RUNTIME_SCHEDULER_AGENT_WORKSPACE_ROOT", defaultWorkspaceRoot))
	hostAgentBin := envDefaultCompat("A2O_HOST_AGENT_BIN", "A3_HOST_AGENT_BIN", resolveDefaultHostAgentBin(config, hostRootDir))
	defaultAgentAttempts := envDefaultValue(packageConfig.AgentAttempts, "220")
	defaultAgentPollInterval := envDefaultValue(packageConfig.AgentPollInterval, "1s")
	defaultAgentControlPlaneConnectTimeout := envDefaultValue(packageConfig.AgentControlPlaneConnectTimeout, "")
	defaultAgentControlPlaneRequestTimeout := envDefaultValue(packageConfig.AgentControlPlaneRequestTimeout, "")
	defaultAgentControlPlaneRetryCount := envDefaultValue(packageConfig.AgentControlPlaneRetryCount, "0")
	defaultAgentControlPlaneRetryDelay := envDefaultValue(packageConfig.AgentControlPlaneRetryDelay, "0s")
	agentAttemptCount, err := parsePositiveInt(envDefaultValue(overrides.AgentAttempts, envDefaultCompat("A2O_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS", "A3_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS", envDefaultCompat("A2O_RUNTIME_SCHEDULER_AGENT_ATTEMPTS", "A3_RUNTIME_SCHEDULER_AGENT_ATTEMPTS", defaultAgentAttempts))), "agent attempts")
	if err != nil {
		return runtimeRunOncePlan{}, err
	}
	defaultAgentIdleLimit := strconv.Itoa(agentAttemptCount)
	agentIdleLimit, err := parseNonNegativeInt(envDefaultCompat("A2O_RUNTIME_RUN_ONCE_AGENT_IDLE_LIMIT", "A3_RUNTIME_RUN_ONCE_AGENT_IDLE_LIMIT", envDefaultCompat("A2O_RUNTIME_SCHEDULER_AGENT_IDLE_LIMIT", "A3_RUNTIME_SCHEDULER_AGENT_IDLE_LIMIT", defaultAgentIdleLimit)), "agent idle limit")
	if err != nil {
		return runtimeRunOncePlan{}, err
	}
	agentPollDuration, err := parseNonNegativeDuration(envDefaultValue(overrides.AgentPollInterval, envDefaultCompat("A2O_RUNTIME_RUN_ONCE_AGENT_POLL_INTERVAL", "A3_RUNTIME_RUN_ONCE_AGENT_POLL_INTERVAL", envDefaultCompat("A2O_RUNTIME_SCHEDULER_AGENT_POLL_INTERVAL", "A3_RUNTIME_SCHEDULER_AGENT_POLL_INTERVAL", defaultAgentPollInterval))), "agent poll interval")
	if err != nil {
		return runtimeRunOncePlan{}, err
	}
	agentControlPlaneConnectTimeout, err := parseOptionalPositiveDuration(envDefaultValue(overrides.AgentControlPlaneConnectTimeout, envDefaultCompat("A2O_RUNTIME_RUN_ONCE_AGENT_CONTROL_PLANE_CONNECT_TIMEOUT", "A3_RUNTIME_RUN_ONCE_AGENT_CONTROL_PLANE_CONNECT_TIMEOUT", envDefaultCompat("A2O_RUNTIME_SCHEDULER_AGENT_CONTROL_PLANE_CONNECT_TIMEOUT", "A3_RUNTIME_SCHEDULER_AGENT_CONTROL_PLANE_CONNECT_TIMEOUT", defaultAgentControlPlaneConnectTimeout))), "agent control plane connect timeout")
	if err != nil {
		return runtimeRunOncePlan{}, err
	}
	agentControlPlaneRequestTimeout, err := parseOptionalPositiveDuration(envDefaultValue(overrides.AgentControlPlaneRequestTimeout, envDefaultCompat("A2O_RUNTIME_RUN_ONCE_AGENT_CONTROL_PLANE_REQUEST_TIMEOUT", "A3_RUNTIME_RUN_ONCE_AGENT_CONTROL_PLANE_REQUEST_TIMEOUT", envDefaultCompat("A2O_RUNTIME_SCHEDULER_AGENT_CONTROL_PLANE_REQUEST_TIMEOUT", "A3_RUNTIME_SCHEDULER_AGENT_CONTROL_PLANE_REQUEST_TIMEOUT", defaultAgentControlPlaneRequestTimeout))), "agent control plane request timeout")
	if err != nil {
		return runtimeRunOncePlan{}, err
	}
	agentControlPlaneRetryCount, err := parseNonNegativeInt(envDefaultValue(overrides.AgentControlPlaneRetries, envDefaultCompat("A2O_RUNTIME_RUN_ONCE_AGENT_CONTROL_PLANE_RETRIES", "A3_RUNTIME_RUN_ONCE_AGENT_CONTROL_PLANE_RETRIES", envDefaultCompat("A2O_RUNTIME_SCHEDULER_AGENT_CONTROL_PLANE_RETRIES", "A3_RUNTIME_SCHEDULER_AGENT_CONTROL_PLANE_RETRIES", defaultAgentControlPlaneRetryCount))), "agent control plane retries")
	if err != nil {
		return runtimeRunOncePlan{}, err
	}
	agentControlPlaneRetryDelay, err := parseNonNegativeDuration(envDefaultValue(overrides.AgentControlPlaneRetryDelay, envDefaultCompat("A2O_RUNTIME_RUN_ONCE_AGENT_CONTROL_PLANE_RETRY_DELAY", "A3_RUNTIME_RUN_ONCE_AGENT_CONTROL_PLANE_RETRY_DELAY", envDefaultCompat("A2O_RUNTIME_SCHEDULER_AGENT_CONTROL_PLANE_RETRY_DELAY", "A3_RUNTIME_SCHEDULER_AGENT_CONTROL_PLANE_RETRY_DELAY", defaultAgentControlPlaneRetryDelay))), "agent control plane retry delay")
	if err != nil {
		return runtimeRunOncePlan{}, err
	}
	target := envDefaultCompat("A2O_RUNTIME_RUN_ONCE_AGENT_TARGET", "A3_RUNTIME_RUN_ONCE_AGENT_TARGET", envDefaultCompat("A2O_RUNTIME_SCHEDULER_AGENT_TARGET", "A3_RUNTIME_SCHEDULER_AGENT_TARGET", ""))
	if strings.TrimSpace(target) == "" {
		detected, err := detectHostTarget()
		if err != nil {
			return runtimeRunOncePlan{}, err
		}
		target = detected
	}
	workerCommand := envDefaultCompat("A2O_RUNTIME_RUN_ONCE_WORKER_COMMAND", "A3_RUNTIME_RUN_ONCE_WORKER_COMMAND", envDefaultCompat("A2O_RUNTIME_SCHEDULER_WORKER_COMMAND", "A3_RUNTIME_SCHEDULER_WORKER_COMMAND", hostAgentBin))
	workerArgs := []string{"worker", "stdin-bundle"}
	if override := envDefaultCompat("A2O_RUNTIME_RUN_ONCE_WORKER_ARGS", "A3_RUNTIME_RUN_ONCE_WORKER_ARGS", envDefaultCompat("A2O_RUNTIME_SCHEDULER_WORKER_ARGS", "A3_RUNTIME_SCHEDULER_WORKER_ARGS", "")); strings.TrimSpace(override) != "" {
		workerArgs = strings.Fields(override)
	}
	if workerScript := envDefaultCompat("A2O_RUNTIME_RUN_ONCE_WORKER", "A3_RUNTIME_RUN_ONCE_WORKER", envDefaultCompat("A2O_RUNTIME_SCHEDULER_WORKER", "A3_RUNTIME_SCHEDULER_WORKER", "")); strings.TrimSpace(workerScript) != "" {
		effectiveWorker := workerScript
		if strings.HasPrefix(effectiveWorker, "/workspace/") {
			effectiveWorker = filepath.Join(hostRootDir, strings.TrimPrefix(effectiveWorker, "/workspace/"))
		}
		workerCommand = "ruby"
		workerArgs = []string{effectiveWorker}
	}
	agentSourcePaths, agentSourceAliases, localSourceAliases, repoSources, repoLabels := packageRuntimeRepoArgs(hostRootDir, effectivePackagePath, packageConfig)
	requiredBins := packageConfig.AgentRequiredBins
	if len(requiredBins) == 0 {
		requiredBins = []string{"git"}
	}
	publishCommitPreflightNativeGitHooks := envDefaultValue(packageConfig.PublishCommitPreflightNativeGitHooks, "bypass")
	defaultMaxSteps := envDefaultValue(packageConfig.MaxSteps, "16")
	defaultLiveRef := envDefaultValue(packageConfig.LiveRef, "refs/heads/feature/prototype")
	defaultKanbanProject := envDefaultValue(config.KanbanProject, packageConfig.KanbanProject)
	defaultKanbanStatus := envDefaultValue(packageConfig.KanbanStatus, "To do")
	launcherConfigPath := envDefaultCompat("A2O_WORKER_LAUNCHER_CONFIG_PATH", "A3_WORKER_LAUNCHER_CONFIG_PATH", filepath.Join(hostRoot, "launcher.json"))
	projectKey := effectiveRuntimeProjectKey(config)
	if len(packageConfig.Executor) == 0 {
		return runtimeRunOncePlan{}, fmt.Errorf("project.yaml runtime.phases.implementation.executor.command is required for packaged a2o-agent worker execution")
	}
	return runtimeRunOncePlan{
		ProjectKey:                      projectKey,
		MultiProjectMode:                config.MultiProjectMode,
		ComposePrefix:                   composeArgs(config),
		MaxSteps:                        envDefaultValue(overrides.MaxSteps, envDefaultCompat("A2O_RUNTIME_RUN_ONCE_MAX_STEPS", "A3_RUNTIME_RUN_ONCE_MAX_STEPS", envDefaultCompat("A2O_RUNTIME_SCHEDULER_MAX_STEPS", "A3_RUNTIME_SCHEDULER_MAX_STEPS", defaultMaxSteps))),
		AgentAttempts:                   agentAttemptCount,
		AgentIdleLimit:                  agentIdleLimit,
		AgentPollInterval:               agentPollDuration,
		AgentControlPlaneConnectTimeout: agentControlPlaneConnectTimeout,
		AgentControlPlaneRequestTimeout: agentControlPlaneRequestTimeout,
		AgentControlPlaneRetryCount:     agentControlPlaneRetryCount,
		AgentControlPlaneRetryDelay:     agentControlPlaneRetryDelay,
		AgentPort:                       effectiveRuntimeAgentPort(config),
		AgentInternalPort:               envDefaultCompat("A2O_RUNTIME_RUN_ONCE_AGENT_INTERNAL_PORT", "A3_RUNTIME_RUN_ONCE_AGENT_INTERNAL_PORT", envDefaultCompat("A2O_RUNTIME_SCHEDULER_AGENT_INTERNAL_PORT", "A3_RUNTIME_SCHEDULER_AGENT_INTERNAL_PORT", "7393")),
		StorageDir:                      envDefaultCompat("A2O_BUNDLE_STORAGE_DIR", "A3_BUNDLE_STORAGE_DIR", envDefaultValue(config.StorageDir, runtimeDefaultStorageDir(config))),
		HostRootDir:                     hostRootDir,
		HostRoot:                        hostRoot,
		WorkspaceRoot:                   workspaceRoot,
		HostAgentBin:                    hostAgentBin,
		HostAgentSource:                 envDefaultCompat("A2O_RUNTIME_RUN_ONCE_AGENT_SOURCE", "A3_RUNTIME_RUN_ONCE_AGENT_SOURCE", envDefaultCompat("A2O_RUNTIME_SCHEDULER_AGENT_SOURCE", "A3_RUNTIME_SCHEDULER_AGENT_SOURCE", "runtime-image")),
		HostAgentTarget:                 target,
		HostAgentLog:                    envDefaultCompat("A2O_RUNTIME_RUN_ONCE_HOST_AGENT_LOG", "A3_RUNTIME_RUN_ONCE_HOST_AGENT_LOG", envDefaultCompat("A2O_RUNTIME_SCHEDULER_HOST_AGENT_LOG", "A3_RUNTIME_SCHEDULER_HOST_AGENT_LOG", filepath.Join(hostRoot, "agent.log"))),
		LiveLogRoot:                     envDefaultCompat("A2O_AGENT_LIVE_LOG_ROOT", "A3_AGENT_LIVE_LOG_ROOT", filepath.Join(hostRoot, "live-logs")),
		AIRawLogRoot:                    envDefaultCompat("A2O_AGENT_AI_RAW_LOG_ROOT", "A3_AGENT_AI_RAW_LOG_ROOT", filepath.Join(hostRoot, "ai-raw-logs")),
		LauncherConfigPath:              launcherConfigPath,
		LauncherConfig:                  packageConfig.Executor,
		ServerLog:                       envDefaultCompat("A2O_RUNTIME_RUN_ONCE_SERVER_LOG", "A3_RUNTIME_RUN_ONCE_SERVER_LOG", envDefaultCompat("A2O_RUNTIME_SCHEDULER_SERVER_LOG", "A3_RUNTIME_SCHEDULER_SERVER_LOG", runtimeProjectTempPath(config, "run-once-agent-server.log"))),
		RuntimeLog:                      envDefaultCompat("A2O_RUNTIME_RUN_ONCE_LOG", "A3_RUNTIME_RUN_ONCE_LOG", envDefaultCompat("A2O_RUNTIME_SCHEDULER_LOG", "A3_RUNTIME_SCHEDULER_LOG", runtimeProjectTempPath(config, "run-once.log"))),
		RuntimeExitFile:                 envDefaultCompat("A2O_RUNTIME_RUN_ONCE_EXIT_FILE", "A3_RUNTIME_RUN_ONCE_EXIT_FILE", envDefaultCompat("A2O_RUNTIME_SCHEDULER_EXIT_FILE", "A3_RUNTIME_SCHEDULER_EXIT_FILE", runtimeProjectTempPath(config, "run-once.exit"))),
		RuntimePIDFile:                  envDefaultCompat("A2O_RUNTIME_RUN_ONCE_PID_FILE", "A3_RUNTIME_RUN_ONCE_PID_FILE", envDefaultCompat("A2O_RUNTIME_SCHEDULER_PID_FILE", "A3_RUNTIME_SCHEDULER_PID_FILE", runtimeProjectTempPath(config, "run-once.pid"))),
		ServerPIDFile:                   envDefaultCompat("A2O_RUNTIME_RUN_ONCE_SERVER_PID_FILE", "A3_RUNTIME_RUN_ONCE_SERVER_PID_FILE", envDefaultCompat("A2O_RUNTIME_SCHEDULER_SERVER_PID_FILE", "A3_RUNTIME_SCHEDULER_SERVER_PID_FILE", runtimeProjectTempPath(config, "run-once-agent-server.pid"))),
		PresetDir:                       envDefaultCompat("A2O_RUNTIME_RUN_ONCE_PRESET_DIR", "A3_RUNTIME_RUN_ONCE_PRESET_DIR", envDefaultCompat("A2O_RUNTIME_SCHEDULER_PRESET_DIR", "A3_RUNTIME_SCHEDULER_PRESET_DIR", "/tmp/a3-engine/config/presets")),
		ManifestPath:                    projectConfigPath,
		SoloBoardInternalURL:            kanbanInternalURL(config),
		LiveRef:                         envDefaultCompat("A2O_RUNTIME_RUN_ONCE_LIVE_REF", "A3_RUNTIME_RUN_ONCE_LIVE_REF", envDefaultCompat("A2O_RUNTIME_SCHEDULER_LIVE_REF", "A3_RUNTIME_SCHEDULER_LIVE_REF", defaultLiveRef)),
		AgentEnv: append([]string{
			"A2O_ROOT_DIR=" + hostRootDir,
			"A2O_WORKER_LAUNCHER_CONFIG_PATH=" + launcherConfigPath,
			"A2O_AGENT_LIVE_LOG_ROOT=" + envDefaultCompat("A2O_AGENT_LIVE_LOG_ROOT", "A3_AGENT_LIVE_LOG_ROOT", filepath.Join(hostRoot, "live-logs")),
			"A2O_AGENT_AI_RAW_LOG_ROOT=" + envDefaultCompat("A2O_AGENT_AI_RAW_LOG_ROOT", "A3_AGENT_AI_RAW_LOG_ROOT", filepath.Join(hostRoot, "ai-raw-logs")),
		}, projectAgentEnv(projectKey, config.MultiProjectMode)...),
		AgentSourcePaths:                          envDefaultListCompat("A2O_RUNTIME_RUN_ONCE_AGENT_SOURCE_PATHS", "A3_RUNTIME_RUN_ONCE_AGENT_SOURCE_PATHS", "A2O_RUNTIME_SCHEDULER_AGENT_SOURCE_PATHS", "A3_RUNTIME_SCHEDULER_AGENT_SOURCE_PATHS", agentSourcePaths),
		AgentRequiredBins:                         envDefaultListCompat("A2O_RUNTIME_RUN_ONCE_AGENT_REQUIRED_BINS", "A3_RUNTIME_RUN_ONCE_AGENT_REQUIRED_BINS", "A2O_RUNTIME_SCHEDULER_AGENT_REQUIRED_BINS", "A3_RUNTIME_SCHEDULER_AGENT_REQUIRED_BINS", requiredBins),
		AgentSourceAliases:                        envDefaultListCompat("A2O_RUNTIME_RUN_ONCE_AGENT_SOURCE_ALIASES", "A3_RUNTIME_RUN_ONCE_AGENT_SOURCE_ALIASES", "A2O_RUNTIME_SCHEDULER_AGENT_SOURCE_ALIASES", "A3_RUNTIME_SCHEDULER_AGENT_SOURCE_ALIASES", agentSourceAliases),
		AgentPublishCommitPreflightNativeGitHooks: publishCommitPreflightNativeGitHooks,
		AgentPublishCommitPreflightCommands:       append([]string{}, packageConfig.PublishCommitPreflightCommands...),
		KanbanProject:                             envDefaultCompat("A2O_RUNTIME_RUN_ONCE_KANBAN_PROJECT", "A3_RUNTIME_RUN_ONCE_KANBAN_PROJECT", envDefaultCompat("A2O_RUNTIME_SCHEDULER_KANBAN_PROJECT", "A3_RUNTIME_SCHEDULER_KANBAN_PROJECT", defaultKanbanProject)),
		KanbanStatus:                              envDefaultCompat("A2O_RUNTIME_RUN_ONCE_KANBAN_STATUS", "A3_RUNTIME_RUN_ONCE_KANBAN_STATUS", envDefaultCompat("A2O_RUNTIME_SCHEDULER_KANBAN_STATUS", "A3_RUNTIME_SCHEDULER_KANBAN_STATUS", defaultKanbanStatus)),
		KanbanRepoLabels:                          envDefaultListCompat("A2O_RUNTIME_RUN_ONCE_KANBAN_REPO_LABELS", "A3_RUNTIME_RUN_ONCE_KANBAN_REPO_LABELS", "A2O_RUNTIME_SCHEDULER_KANBAN_REPO_LABELS", "A3_RUNTIME_SCHEDULER_KANBAN_REPO_LABELS", repoLabels),
		RepoSources:                               envDefaultListCompat("A2O_RUNTIME_RUN_ONCE_REPO_SOURCES", "A3_RUNTIME_RUN_ONCE_REPO_SOURCES", "A2O_RUNTIME_SCHEDULER_REPO_SOURCES", "A3_RUNTIME_SCHEDULER_REPO_SOURCES", repoSources),
		LocalSourceAliases:                        envDefaultListCompat("A2O_RUNTIME_RUN_ONCE_LOCAL_SOURCE_ALIASES", "A3_RUNTIME_RUN_ONCE_LOCAL_SOURCE_ALIASES", "A2O_RUNTIME_SCHEDULER_LOCAL_SOURCE_ALIASES", "A3_RUNTIME_SCHEDULER_LOCAL_SOURCE_ALIASES", localSourceAliases),
		WorkerCommand:                             workerCommand,
		WorkerArgs:                                workerArgs,
		JobTimeoutSeconds:                         envDefaultCompat("A2O_RUNTIME_RUN_ONCE_AGENT_JOB_TIMEOUT_SECONDS", "A3_RUNTIME_RUN_ONCE_AGENT_JOB_TIMEOUT_SECONDS", envDefaultCompat("A2O_RUNTIME_SCHEDULER_AGENT_JOB_TIMEOUT_SECONDS", "A3_RUNTIME_SCHEDULER_AGENT_JOB_TIMEOUT_SECONDS", "7200")),
		BranchNamespace:                           defaultProjectBranchNamespace(config),
	}, nil
}

func validateRuntimeProjectSideEffectScope(config runtimeInstanceConfig) error {
	if !config.MultiProjectMode {
		return nil
	}
	projectKey := effectiveRuntimeProjectKey(config)
	if projectKey == "" {
		return fmt.Errorf("multi-project runtime side effects require a resolved project key")
	}
	if safeRuntimeLogComponent(projectKey) != projectKey {
		return fmt.Errorf("multi-project runtime side effects require a safe project key %q; use ASCII letters, numbers, '.', '_', '-', or ':'", projectKey)
	}
	return nil
}

func effectiveRuntimeProjectKey(config runtimeInstanceConfig) string {
	return strings.TrimSpace(config.ProjectKey)
}

func safeProjectKeyComponent(projectKey string) string {
	safeKey := safeRuntimeLogComponent(strings.TrimSpace(projectKey))
	if safeKey == "" {
		return "default"
	}
	return safeKey
}

func runtimeDefaultStorageDir(config runtimeInstanceConfig) string {
	if !config.MultiProjectMode {
		return "/var/lib/a2o/a2o-runtime"
	}
	return filepath.Join("/var/lib/a2o/projects", safeProjectKeyComponent(config.ProjectKey))
}

func runtimeProjectHostRoot(hostRootDir string, config runtimeInstanceConfig) string {
	if !config.MultiProjectMode {
		return filepath.Join(hostRootDir, runtimeHostAgentRelativePath)
	}
	return filepath.Join(runtimeProjectHostSideEffectRoot(hostRootDir, config), "runtime-host-agent")
}

func runtimeProjectAgentWorkspaceRoot(hostRootDir string, config runtimeInstanceConfig, configured string) string {
	trimmed := strings.TrimSpace(configured)
	if trimmed == "" {
		return filepath.Join(runtimeProjectHostRoot(hostRootDir, config), "workspaces")
	}
	if !config.MultiProjectMode || filepath.IsAbs(trimmed) {
		return resolvePackagePath(hostRootDir, trimmed)
	}
	return filepath.Join(runtimeProjectHostSideEffectRoot(hostRootDir, config), trimmed)
}

func runtimeProjectHostSideEffectRoot(hostRootDir string, config runtimeInstanceConfig) string {
	return filepath.Join(hostRootDir, ".work", "a2o", "projects", safeProjectKeyComponent(config.ProjectKey))
}

func runtimeProjectTempPath(config runtimeInstanceConfig, suffix string) string {
	if !config.MultiProjectMode {
		return filepath.Join("/tmp", "a2o-runtime-"+suffix)
	}
	return filepath.Join("/tmp", "a2o-runtime-"+safeProjectKeyComponent(config.ProjectKey)+"-"+suffix)
}

func defaultProjectBranchNamespace(config runtimeInstanceConfig) string {
	base := defaultBranchNamespace(config.ComposeProject)
	if !config.MultiProjectMode {
		return base
	}
	return base + "-" + safeProjectKeyComponent(config.ProjectKey)
}

func projectAgentEnv(projectKey string, multiProjectMode bool) []string {
	env := []string{}
	if strings.TrimSpace(projectKey) != "" {
		env = append(env, "A2O_PROJECT_KEY="+strings.TrimSpace(projectKey))
	}
	if multiProjectMode {
		env = append(env, "A2O_MULTI_PROJECT_MODE=1")
	}
	return env
}

func buildRuntimeDescribeTaskPlan(config runtimeInstanceConfig) (runtimeRunOncePlan, error) {
	if err := validateRuntimeProjectSideEffectScope(config); err != nil {
		return runtimeRunOncePlan{}, err
	}
	if config.MultiProjectMode {
		config.ProjectKey = effectiveRuntimeProjectKey(config)
	}
	hostRootDir := envDefaultCompat("A2O_RUNTIME_RUN_ONCE_HOST_ROOT_DIR", "A3_RUNTIME_RUN_ONCE_HOST_ROOT_DIR", envDefaultCompat("A2O_RUNTIME_SCHEDULER_HOST_ROOT_DIR", "A3_RUNTIME_SCHEDULER_HOST_ROOT_DIR", config.WorkspaceRoot))
	if strings.TrimSpace(hostRootDir) == "" {
		hostRootDir = "."
	}
	referencePackagePath := envDefaultCompat("A2O_RUNTIME_RUN_ONCE_REFERENCE_PACKAGE", "A3_RUNTIME_RUN_ONCE_REFERENCE_PACKAGE", envDefaultCompat("A2O_RUNTIME_SCHEDULER_REFERENCE_PACKAGE", "A3_RUNTIME_SCHEDULER_REFERENCE_PACKAGE", config.PackagePath))
	if strings.TrimSpace(referencePackagePath) == "" {
		return runtimeRunOncePlan{}, errors.New("runtime package path is empty; run `a2o project bootstrap` from a workspace with ./a2o-project or ./project-package first")
	}
	packageConfig, err := loadProjectPackageConfig(referencePackagePath)
	if err != nil {
		return runtimeRunOncePlan{}, err
	}
	hostRoot := envDefaultCompat("A2O_RUNTIME_RUN_ONCE_HOST_ROOT", "A3_RUNTIME_RUN_ONCE_HOST_ROOT", envDefaultCompat("A2O_RUNTIME_SCHEDULER_HOST_ROOT", "A3_RUNTIME_SCHEDULER_HOST_ROOT", runtimeProjectHostRoot(hostRootDir, config)))
	_, _, _, _, repoLabels := packageRuntimeRepoArgs(hostRootDir, referencePackagePath, packageConfig)
	return runtimeRunOncePlan{
		ComposePrefix:        composeArgs(config),
		StorageDir:           envDefaultCompat("A2O_BUNDLE_STORAGE_DIR", "A3_BUNDLE_STORAGE_DIR", envDefaultValue(config.StorageDir, runtimeDefaultStorageDir(config))),
		HostAgentLog:         envDefaultCompat("A2O_RUNTIME_RUN_ONCE_HOST_AGENT_LOG", "A3_RUNTIME_RUN_ONCE_HOST_AGENT_LOG", envDefaultCompat("A2O_RUNTIME_SCHEDULER_HOST_AGENT_LOG", "A3_RUNTIME_SCHEDULER_HOST_AGENT_LOG", filepath.Join(hostRoot, "agent.log"))),
		LiveLogRoot:          envDefaultCompat("A2O_AGENT_LIVE_LOG_ROOT", "A3_AGENT_LIVE_LOG_ROOT", filepath.Join(hostRoot, "live-logs")),
		AIRawLogRoot:         envDefaultCompat("A2O_AGENT_AI_RAW_LOG_ROOT", "A3_AGENT_AI_RAW_LOG_ROOT", filepath.Join(hostRoot, "ai-raw-logs")),
		ServerLog:            envDefaultCompat("A2O_RUNTIME_RUN_ONCE_SERVER_LOG", "A3_RUNTIME_RUN_ONCE_SERVER_LOG", envDefaultCompat("A2O_RUNTIME_SCHEDULER_SERVER_LOG", "A3_RUNTIME_SCHEDULER_SERVER_LOG", runtimeProjectTempPath(config, "run-once-agent-server.log"))),
		RuntimeLog:           envDefaultCompat("A2O_RUNTIME_RUN_ONCE_LOG", "A3_RUNTIME_RUN_ONCE_LOG", envDefaultCompat("A2O_RUNTIME_SCHEDULER_LOG", "A3_RUNTIME_SCHEDULER_LOG", runtimeProjectTempPath(config, "run-once.log"))),
		RuntimeExitFile:      envDefaultCompat("A2O_RUNTIME_RUN_ONCE_EXIT_FILE", "A3_RUNTIME_RUN_ONCE_EXIT_FILE", envDefaultCompat("A2O_RUNTIME_SCHEDULER_EXIT_FILE", "A3_RUNTIME_SCHEDULER_EXIT_FILE", runtimeProjectTempPath(config, "run-once.exit"))),
		PresetDir:            envDefaultCompat("A2O_RUNTIME_RUN_ONCE_PRESET_DIR", "A3_RUNTIME_RUN_ONCE_PRESET_DIR", envDefaultCompat("A2O_RUNTIME_SCHEDULER_PRESET_DIR", "A3_RUNTIME_SCHEDULER_PRESET_DIR", "/tmp/a3-engine/config/presets")),
		ManifestPath:         envDefaultCompat("A2O_RUNTIME_RUN_ONCE_PROJECT_CONFIG", "A3_RUNTIME_RUN_ONCE_PROJECT_CONFIG", envDefaultCompat("A2O_RUNTIME_SCHEDULER_PROJECT_CONFIG", "A3_RUNTIME_SCHEDULER_PROJECT_CONFIG", filepath.Join(referencePackagePath, "project.yaml"))),
		SoloBoardInternalURL: kanbanInternalURL(config),
		KanbanProject:        envDefaultCompat("A2O_RUNTIME_RUN_ONCE_KANBAN_PROJECT", "A3_RUNTIME_RUN_ONCE_KANBAN_PROJECT", envDefaultCompat("A2O_RUNTIME_SCHEDULER_KANBAN_PROJECT", "A3_RUNTIME_SCHEDULER_KANBAN_PROJECT", envDefaultValue(config.KanbanProject, packageConfig.KanbanProject))),
		KanbanStatus:         envDefaultCompat("A2O_RUNTIME_RUN_ONCE_KANBAN_STATUS", "A3_RUNTIME_RUN_ONCE_KANBAN_STATUS", envDefaultCompat("A2O_RUNTIME_SCHEDULER_KANBAN_STATUS", "A3_RUNTIME_SCHEDULER_KANBAN_STATUS", envDefaultValue(packageConfig.KanbanStatus, "To do"))),
		KanbanRepoLabels:     envDefaultListCompat("A2O_RUNTIME_RUN_ONCE_KANBAN_REPO_LABELS", "A3_RUNTIME_RUN_ONCE_KANBAN_REPO_LABELS", "A2O_RUNTIME_SCHEDULER_KANBAN_REPO_LABELS", "A3_RUNTIME_SCHEDULER_KANBAN_REPO_LABELS", repoLabels),
	}, nil
}

func kanbanInternalURL(config runtimeInstanceConfig) string {
	return kanbanRuntimeURL(config)
}

func runtimeDescribeSectionOutput(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, section string, argv ...string) (string, error) {
	output, err := dockerComposeExecOutput(config, plan, runner, argv...)
	if err != nil {
		return "", fmt.Errorf("%s command failed: %w", section, err)
	}
	return strings.TrimRight(string(output), "\n"), nil
}

func runtimeInspectionArgs(argv ...string) []string {
	script := strings.Join([]string{
		`export A3_SECRET="${A3_SECRET:-a2o-runtime-secret}"`,
		`export A3_SECRET_REFERENCE="${A3_SECRET_REFERENCE:-A3_SECRET}"`,
		`export A2O_INTERNAL_SECRET_REFERENCE="${A2O_INTERNAL_SECRET_REFERENCE:-a2o-runtime-secret}"`,
		"exec " + shellJoin(argv),
	}, "; ")
	return []string{"bash", "-lc", script}
}

func runtimeWatchSummaryArgs(plan runtimeRunOncePlan, details bool) []string {
	args := []string{"a3", "watch-summary", "--storage-backend", "json", "--storage-dir", plan.StorageDir}
	if details {
		args = append(args, "--details")
	}
	if strings.TrimSpace(plan.KanbanProject) == "" || len(plan.KanbanRepoLabels) == 0 {
		return args
	}
	args = append(args,
		"--kanban-command", "python3",
		"--kanban-command-arg", packagedKanbanCLIPath,
		"--kanban-command-arg", "--backend",
		"--kanban-command-arg", "kanbalone",
		"--kanban-command-arg", "--base-url",
		"--kanban-command-arg", plan.SoloBoardInternalURL,
		"--kanban-project", plan.KanbanProject,
		"--kanban-working-dir", "/workspace",
	)
	for _, repoLabel := range plan.KanbanRepoLabels {
		args = append(args, "--kanban-repo-label", repoLabel)
	}
	return args
}

func latestRuntimeRunRef(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, taskRef string) (string, error) {
	script := "records = JSON.parse(File.read(ARGV.fetch(0))); run = records.values.select { |record| record['task_ref'] == ARGV.fetch(1) }.last; puts(run['ref']) if run"
	output, err := dockerComposeExecOutput(config, plan, runner, "ruby", "-rjson", "-e", script, path.Join(plan.StorageDir, "runs.json"), taskRef)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(output)), nil
}

func printDescribeSection(stdout io.Writer, name string, output string) {
	fmt.Fprintf(stdout, "--- %s ---\n", name)
	if strings.TrimSpace(output) == "" {
		fmt.Fprintln(stdout, "(empty)")
		return
	}
	fmt.Fprintln(stdout, output)
}

func printDescribeKanbanSection(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer, taskRef string) {
	taskOutput, taskErr := runtimeDescribeSectionOutput(config, plan, runner, "kanban_task", "python3", packagedKanbanCLIPath, "--backend", "kanbalone", "--base-url", plan.SoloBoardInternalURL, "task-get", "--project", plan.KanbanProject, "--task", taskRef)
	if taskErr != nil {
		fmt.Fprintf(stdout, "describe_section name=kanban_task status=blocked action=check kanban service detail=%s\n", singleLine(taskErr.Error()))
	} else {
		printDescribeSection(stdout, "kanban_task", taskOutput)
	}

	commentOutput, commentErr := runtimeDescribeSectionOutput(config, plan, runner, "kanban_comments", "python3", packagedKanbanCLIPath, "--backend", "kanbalone", "--base-url", plan.SoloBoardInternalURL, "task-comment-list", "--project", plan.KanbanProject, "--task", taskRef)
	if commentErr != nil {
		fmt.Fprintf(stdout, "describe_section name=kanban_comments status=blocked action=check kanban service detail=%s\n", singleLine(commentErr.Error()))
		return
	}
	printDescribeComments(stdout, commentOutput)
}

func printDescribeComments(stdout io.Writer, output string) {
	fmt.Fprintln(stdout, "--- kanban_comments ---")
	var comments []struct {
		ID      int    `json:"id"`
		Comment string `json:"comment"`
		Updated string `json:"updated"`
		Created string `json:"created"`
	}
	if err := json.Unmarshal([]byte(output), &comments); err != nil {
		if strings.TrimSpace(output) == "" {
			fmt.Fprintln(stdout, "(empty)")
			return
		}
		fmt.Fprintln(stdout, output)
		return
	}
	fmt.Fprintf(stdout, "comment_count=%d\n", len(comments))
	for index, comment := range comments {
		when := firstNonEmpty(comment.Updated, comment.Created)
		fmt.Fprintf(stdout, "comment[%d] id=%d updated=%s body=%s\n", index, comment.ID, when, singleLine(comment.Comment))
	}
}

func parseOutputValue(output string, key string) string {
	prefix := key + "="
	for _, field := range strings.Fields(output) {
		if strings.HasPrefix(field, prefix) {
			return strings.TrimSpace(strings.TrimPrefix(field, prefix))
		}
	}
	return ""
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func defaultBranchNamespace(composeProject string) string {
	namespace := strings.Trim(strings.ToLower(strings.TrimSpace(composeProject)), "-")
	namespace = strings.TrimPrefix(namespace, "a3-")
	if namespace == "" {
		return "runtime"
	}
	return namespace
}

func packageRuntimeRepoArgs(hostRootDir string, packagePath string, config projectPackageConfig) ([]string, []string, []string, []string, []string) {
	agentSourcePaths := []string{}
	agentSourceAliases := []string{}
	localSourceAliases := []string{}
	repoSources := []string{}
	repoLabels := []string{}
	for _, alias := range sortedProjectRepoAliases(config.Repos) {
		repo := config.Repos[alias]
		sourceAlias := alias
		hostPath := resolvePackagePath(packagePath, repo.Path)
		agentSourcePaths = append(agentSourcePaths, sourceAlias+"="+hostPath)
		agentSourceAliases = append(agentSourceAliases, alias+"="+sourceAlias)
		localSourceAliases = append(localSourceAliases, sourceAlias+"="+hostPath)
		repoSources = append(repoSources, alias+"="+workspaceContainerPath(hostRootDir, hostPath))
		label := repo.Label
		if strings.TrimSpace(label) == "" {
			label = "repo:" + alias
		}
		repoLabels = append(repoLabels, label+"="+alias)
	}
	return agentSourcePaths, agentSourceAliases, localSourceAliases, repoSources, repoLabels
}

func envDefaultList(runOnceName string, schedulerName string, defaults []string) []string {
	value := envDefault(runOnceName, envDefault(schedulerName, ""))
	if strings.TrimSpace(value) == "" {
		return append([]string{}, defaults...)
	}
	parts := strings.Split(value, ";")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

func envDefaultListCompat(publicRunOnceName string, legacyRunOnceName string, publicSchedulerName string, legacySchedulerName string, defaults []string) []string {
	value := envDefaultCompat(publicRunOnceName, legacyRunOnceName, envDefaultCompat(publicSchedulerName, legacySchedulerName, ""))
	if strings.TrimSpace(value) == "" {
		return append([]string{}, defaults...)
	}
	parts := strings.Split(value, ";")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

func archiveRuntimeStateIfRequested(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer) error {
	if envDefaultCompat("A2O_RUNTIME_RUN_ONCE_ARCHIVE_STATE", "A3_RUNTIME_RUN_ONCE_ARCHIVE_STATE", envDefaultCompat("A2O_RUNTIME_SCHEDULER_ARCHIVE_STATE", "A3_RUNTIME_SCHEDULER_ARCHIVE_STATE", "0")) != "1" {
		return nil
	}
	fmt.Fprintf(stdout, "runtime_archive_state storage=%s\n", plan.StorageDir)
	if err := dockerComposeExec(config, plan, runner, "mkdir", "-p", "/var/lib/a2o/archive"); err != nil {
		return err
	}
	if _, err := dockerComposeExecOutput(config, plan, runner, "test", "-e", plan.StorageDir); err == nil {
		stampBytes, err := dockerComposeExecOutput(config, plan, runner, "date", "-u", "+%Y%m%dT%H%M%SZ")
		if err != nil {
			return err
		}
		stamp := strings.TrimSpace(string(stampBytes))
		archivePath := path.Join("/var/lib/a2o/archive", path.Base(plan.StorageDir)+"-"+stamp)
		if err := dockerComposeExec(config, plan, runner, "mv", plan.StorageDir, archivePath); err != nil {
			return err
		}
	}
	return dockerComposeExec(config, plan, runner, "mkdir", "-p", plan.StorageDir)
}

func cleanupRuntimeProcesses(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner) error {
	stopRuntimeActiveProcesses(config, plan, runner)
	return dockerComposeExec(config, plan, runner, "rm", "-f", plan.RuntimeExitFile, plan.ServerLog, plan.RuntimeLog)
}

func stopRuntimeActiveProcesses(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner) {
	killRuntimeProcessesByPattern(config, plan, runner, "a3 execute-until-idle")
	killRuntimeProcessesByPattern(config, plan, runner, "a3 agent-server")
	killRuntimePIDFile(config, plan, runner, plan.RuntimePIDFile)
	killRuntimePIDFile(config, plan, runner, plan.ServerPIDFile)
}

func repairRuntimeRuns(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer, reason string) error {
	fmt.Fprintf(stdout, "runtime_repair_runs reason=%s\n", reason)
	output, err := dockerComposeExecOutput(config, plan, runner, "a3", "repair-runs", "--storage-backend", "json", "--storage-dir", plan.StorageDir, "--apply")
	if strings.TrimSpace(string(output)) != "" {
		fmt.Fprint(stdout, string(output))
		if !strings.HasSuffix(string(output), "\n") {
			fmt.Fprintln(stdout)
		}
	}
	if err != nil {
		return fmt.Errorf("repair runtime runs: %w", err)
	}
	return nil
}

func ensureRuntimeHostAgent(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer) error {
	if err := os.MkdirAll(filepath.Dir(plan.HostAgentBin), 0o755); err != nil {
		return fmt.Errorf("create host agent bin directory: %w", err)
	}
	if err := os.MkdirAll(plan.WorkspaceRoot, 0o755); err != nil {
		return fmt.Errorf("create agent workspace root: %w", err)
	}
	switch plan.HostAgentSource {
	case "runtime-image":
		fmt.Fprintf(stdout, "runtime_agent_export target=%s output=%s\n", plan.HostAgentTarget, plan.HostAgentBin)
		containerID, err := runtimeContainerID(config, plan, runner)
		if err != nil {
			return err
		}
		if _, err := runExternal(runner, "docker", "exec", containerID, "a2o", "agent", "package", "verify", "--target", plan.HostAgentTarget); err != nil {
			return err
		}
		if _, err := runExternal(runner, "docker", "exec", containerID, "a2o", "agent", "package", "export", "--target", plan.HostAgentTarget, "--output", "/tmp/a2o-runtime-run-once-agent"); err != nil {
			return err
		}
		if _, err := runExternal(runner, "docker", "cp", containerID+":/tmp/a2o-runtime-run-once-agent", plan.HostAgentBin); err != nil {
			return err
		}
		return os.Chmod(plan.HostAgentBin, 0o755)
	case "source":
		fmt.Fprintf(stdout, "runtime_agent_build output=%s\n", plan.HostAgentBin)
		buildDir := filepath.Join(plan.HostRootDir, "a3-engine", "agent-go")
		_, err := runExternal(runner, "bash", "-lc", "cd "+shellQuote(buildDir)+" && go build -trimpath -o "+shellQuote(plan.HostAgentBin)+" ./cmd/a3-agent")
		return err
	default:
		return fmt.Errorf("unsupported A2O_RUNTIME_RUN_ONCE_AGENT_SOURCE: %s", plan.HostAgentSource)
	}
}

func runtimeContainerID(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner) (string, error) {
	output, err := runExternal(runner, "docker", append(plan.ComposePrefix, "ps", "-q", config.RuntimeService)...)
	if err != nil {
		return "", err
	}
	containerID := strings.TrimSpace(string(output))
	if containerID == "" {
		return "", fmt.Errorf("A2O runtime container not found; run a2o runtime up%s", runtimeProjectCommandArg(plan.ProjectKey, plan.MultiProjectMode))
	}
	return containerID, nil
}

func dockerComposeExecArgs(config runtimeInstanceConfig, plan runtimeRunOncePlan, argv ...string) []string {
	args := append([]string{}, plan.ComposePrefix...)
	args = append(args, "exec", "-T", config.RuntimeService)
	args = append(args, argv...)
	return args
}

func dockerComposeExec(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, argv ...string) error {
	_, err := dockerComposeExecOutput(config, plan, runner, argv...)
	return err
}

func dockerComposeExecOutput(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, argv ...string) ([]byte, error) {
	return runExternal(runner, "docker", dockerComposeExecArgs(config, plan, argv...)...)
}

func dockerComposeExecShell(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, script string) error {
	return dockerComposeExec(config, plan, runner, "bash", "-lc", script)
}

func dockerComposeExecBestEffort(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, argv ...string) []byte {
	output, _ := runner.Run("docker", dockerComposeExecArgs(config, plan, argv...)...)
	return output
}

type runtimeContainerProcess struct {
	WorkingDir  string
	Env         map[string]string
	EnvShell    map[string]string
	Args        []string
	StdoutPath  string
	PIDFile     string
	ExitFile    string
	StderrToOut bool
}

func (process runtimeContainerProcess) shellScript() string {
	command := shellJoin(process.Args)
	if process.StdoutPath != "" {
		command += " > " + shellQuote(process.StdoutPath)
		if process.StderrToOut {
			command += " 2>&1"
		}
	}

	prefix := process.envExport()
	if process.ExitFile != "" {
		if prefix != "" {
			command = prefix + "; " + command
		}
		command = "(" + command + "; echo $? > " + shellQuote(process.ExitFile) + ")"
	} else if prefix != "" {
		command = "(" + prefix + "; " + command + ")"
	}

	if process.WorkingDir != "" {
		command = "cd " + shellQuote(process.WorkingDir) + " && " + command
	}
	if process.PIDFile != "" {
		command += " & echo $! > " + shellQuote(process.PIDFile)
	}
	return command
}

func (process runtimeContainerProcess) envExport() string {
	if len(process.Env) == 0 && len(process.EnvShell) == 0 {
		return ""
	}
	keys := make([]string, 0, len(process.Env))
	for key := range process.Env {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	assignments := make([]string, 0, len(keys))
	for _, key := range keys {
		assignments = append(assignments, key+"="+shellQuote(process.Env[key]))
	}
	shellKeys := make([]string, 0, len(process.EnvShell))
	for key := range process.EnvShell {
		shellKeys = append(shellKeys, key)
	}
	sort.Strings(shellKeys)
	for _, key := range shellKeys {
		assignments = append(assignments, key+"="+process.EnvShell[key])
	}
	return "export " + strings.Join(assignments, " ")
}

func killRuntimeProcessesByPattern(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, pattern string) {
	output, err := dockerComposeExecOutput(config, plan, runner, "pgrep", "-f", pattern)
	if err != nil {
		return
	}
	for _, pid := range strings.Fields(string(output)) {
		_ = dockerComposeExec(config, plan, runner, "kill", pid)
	}
}

func killRuntimePIDFile(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, pidFile string) {
	output, err := dockerComposeExecOutput(config, plan, runner, "cat", pidFile)
	if err == nil {
		if pid := strings.TrimSpace(string(output)); pid != "" {
			_ = dockerComposeExec(config, plan, runner, "kill", pid)
		}
	}
	_ = dockerComposeExec(config, plan, runner, "rm", "-f", pidFile)
}

func startRuntimeAgentServer(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer) error {
	fmt.Fprintf(stdout, "runtime_agent_server_start port=%s host_port=%s\n", plan.AgentInternalPort, plan.AgentPort)
	env := map[string]string{}
	if strings.TrimSpace(plan.ProjectKey) != "" {
		env["A2O_PROJECT_KEY"] = strings.TrimSpace(plan.ProjectKey)
	}
	if plan.MultiProjectMode {
		env["A2O_MULTI_PROJECT_MODE"] = "1"
	}
	return dockerComposeExecShell(config, plan, runner, runtimeContainerProcess{
		WorkingDir:  "/workspace",
		Env:         env,
		Args:        []string{"a3", "agent-server", "--storage-dir", plan.StorageDir, "--host", "0.0.0.0", "--port", plan.AgentInternalPort},
		StdoutPath:  plan.ServerLog,
		StderrToOut: true,
		PIDFile:     plan.ServerPIDFile,
	}.shellScript())
}

func startRuntimeAgentServerUnlessReady(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer) error {
	if runtimeControlPlaneReady(plan, runner) {
		fmt.Fprintf(stdout, "runtime_agent_server_reuse port=%s host_port=%s\n", plan.AgentInternalPort, plan.AgentPort)
		return nil
	}
	return startRuntimeAgentServer(config, plan, runner, stdout)
}

func waitForRuntimeControlPlane(plan runtimeRunOncePlan, runner commandRunner) error {
	if runtimeControlPlaneReady(plan, runner) {
		return nil
	}
	probeURL := runtimeControlPlaneProbeURL(plan)
	var lastErr error
	for i := 0; i < 80; i++ {
		if _, err := runExternal(runner, "curl", "-fsS", probeURL); err == nil {
			return nil
		} else {
			lastErr = err
		}
		time.Sleep(250 * time.Millisecond)
	}
	return fmt.Errorf("agent control plane did not become ready: %w", lastErr)
}

func runtimeControlPlaneReady(plan runtimeRunOncePlan, runner commandRunner) bool {
	_, err := runExternal(runner, "curl", "-fsS", runtimeControlPlaneProbeURL(plan))
	return err == nil
}

func runtimeControlPlaneProbeURL(plan runtimeRunOncePlan) string {
	return fmt.Sprintf("http://127.0.0.1:%s/v1/agent/health", plan.AgentPort)
}

func startRuntimeExecuteUntilIdle(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer) error {
	fmt.Fprintf(stdout, "runtime_execute_until_idle_start max_steps=%s\n", plan.MaxSteps)
	env := map[string]string{
		"A2O_BRANCH_NAMESPACE": plan.BranchNamespace,
		"A2O_ROOT_DIR":         "/workspace",
		"KANBAN_BACKEND":       "kanbalone",
	}
	if strings.TrimSpace(plan.ProjectKey) != "" {
		env["A2O_PROJECT_KEY"] = strings.TrimSpace(plan.ProjectKey)
	}
	if plan.MultiProjectMode {
		env["A2O_MULTI_PROJECT_MODE"] = "1"
	}
	return dockerComposeExecShell(config, plan, runner, runtimeContainerProcess{
		WorkingDir: "/workspace",
		Env:        env,
		EnvShell: map[string]string{
			"A3_SECRET":           "${A3_SECRET:-a2o-runtime-secret}",
			"A3_SECRET_REFERENCE": "${A3_SECRET_REFERENCE:-A3_SECRET}",
		},
		Args:        executeUntilIdleArgs(plan),
		StdoutPath:  plan.RuntimeLog,
		StderrToOut: true,
		ExitFile:    plan.RuntimeExitFile,
		PIDFile:     plan.RuntimePIDFile,
	}.shellScript())
}

func executeUntilIdleArgs(plan runtimeRunOncePlan) []string {
	args := []string{
		"a3", "execute-until-idle",
		"--preset-dir", plan.PresetDir,
		"--storage-backend", "json",
		"--storage-dir", plan.StorageDir,
		"--worker-gateway", "agent-http",
		"--verification-command-runner", "agent-http",
		"--merge-runner", "agent-http",
		"--agent-control-plane-url", "http://127.0.0.1:" + plan.AgentInternalPort,
		"--agent-runtime-profile", "host-local",
		"--agent-shared-workspace-mode", "agent-materialized",
		"--agent-support-ref", plan.LiveRef,
		"--agent-workspace-root", plan.WorkspaceRoot,
		"--agent-workspace-cleanup-policy", "cleanup_after_job",
		"--agent-publish-commit-preflight-native-git-hooks", plan.AgentPublishCommitPreflightNativeGitHooks,
		"--agent-job-timeout-seconds", plan.JobTimeoutSeconds,
		"--agent-job-poll-interval-seconds", "1.0",
		"--worker-command", plan.WorkerCommand,
	}
	for _, agentEnv := range plan.AgentEnv {
		args = append(args, "--agent-env", agentEnv)
	}
	for _, command := range plan.AgentPublishCommitPreflightCommands {
		args = append(args, "--agent-publish-commit-preflight-command", command)
	}
	for _, sourcePath := range plan.AgentSourcePaths {
		args = append(args, "--agent-source-path", sourcePath)
	}
	for _, requiredBin := range plan.AgentRequiredBins {
		args = append(args, "--agent-required-bin", requiredBin)
	}
	for _, sourceAlias := range plan.AgentSourceAliases {
		args = append(args, "--agent-source-alias", sourceAlias)
	}
	for _, workerArg := range plan.WorkerArgs {
		args = append(args, "--worker-command-arg", workerArg)
	}
	args = append(args,
		"--kanban-command", "python3",
		"--kanban-command-arg", packagedKanbanCLIPath,
		"--kanban-command-arg", "--backend",
		"--kanban-command-arg", "kanbalone",
		"--kanban-command-arg", "--base-url",
		"--kanban-command-arg", plan.SoloBoardInternalURL,
		"--kanban-project", plan.KanbanProject,
		"--kanban-status", plan.KanbanStatus,
		"--kanban-working-dir", "/workspace",
		"--kanban-follow-up-label", "a2o:follow-up-child",
		"--kanban-trigger-label", "trigger:auto-implement",
		"--kanban-trigger-label", "trigger:auto-parent",
	)
	for _, repoLabel := range plan.KanbanRepoLabels {
		args = append(args, "--kanban-repo-label", repoLabel)
	}
	for _, repoSource := range plan.RepoSources {
		args = append(args, "--repo-source", repoSource)
	}
	args = append(args, "--max-steps", plan.MaxSteps, plan.ManifestPath)
	return args
}

func runHostAgentLoop(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer) error {
	fmt.Fprintf(stdout, "runtime_host_agent_loop attempts=%d poll_interval=%s connect_timeout=%s request_timeout=%s retries=%d retry_delay=%s\n",
		plan.AgentAttempts,
		plan.AgentPollInterval,
		formatOptionalDuration(plan.AgentControlPlaneConnectTimeout),
		formatOptionalDuration(plan.AgentControlPlaneRequestTimeout),
		plan.AgentControlPlaneRetryCount,
		plan.AgentControlPlaneRetryDelay,
	)
	_ = appendFile(plan.HostAgentLog, []byte(fmt.Sprintf(
		"\n===== host agent session start %s attempts=%d poll_interval=%s connect_timeout=%s request_timeout=%s retries=%d retry_delay=%s =====\n",
		time.Now().UTC().Format(time.RFC3339),
		plan.AgentAttempts,
		plan.AgentPollInterval,
		formatOptionalDuration(plan.AgentControlPlaneConnectTimeout),
		formatOptionalDuration(plan.AgentControlPlaneRequestTimeout),
		plan.AgentControlPlaneRetryCount,
		plan.AgentControlPlaneRetryDelay,
	)))
	var agentStatus error
	consecutiveIdle := 0
	attemptsSinceProgress := 0
	for attempt := 1; ; attempt++ {
		attemptsSinceProgress++
		fmt.Fprintf(stdout, "runtime_host_agent_attempt=%d\n", attempt)
		args := []string{"-agent", "host-local", "-control-plane-url", "http://127.0.0.1:" + plan.AgentPort}
		if strings.TrimSpace(plan.ProjectKey) != "" {
			args = append(args, "-project", strings.TrimSpace(plan.ProjectKey))
		}
		if plan.AgentControlPlaneConnectTimeout > 0 {
			args = append(args, "-control-plane-connect-timeout", plan.AgentControlPlaneConnectTimeout.String())
		}
		if plan.AgentControlPlaneRequestTimeout > 0 {
			args = append(args, "-control-plane-request-timeout", plan.AgentControlPlaneRequestTimeout.String())
		}
		args = append(args, "-control-plane-retries", strconv.Itoa(plan.AgentControlPlaneRetryCount))
		if plan.AgentControlPlaneRetryDelay > 0 {
			args = append(args, "-control-plane-retry-delay", plan.AgentControlPlaneRetryDelay.String())
		}
		if envDefaultCompat("A2O_RUNTIME_RUN_ONCE_AGENT_LOCAL_MATERIALIZER_ARGS", "A3_RUNTIME_RUN_ONCE_AGENT_LOCAL_MATERIALIZER_ARGS", envDefaultCompat("A2O_RUNTIME_SCHEDULER_AGENT_LOCAL_MATERIALIZER_ARGS", "A3_RUNTIME_SCHEDULER_AGENT_LOCAL_MATERIALIZER_ARGS", "0")) == "1" {
			args = append(args, "-workspace-root", plan.WorkspaceRoot)
			for _, sourceAlias := range plan.LocalSourceAliases {
				args = append(args, "-source-alias", sourceAlias)
			}
		}
		_ = appendFile(plan.HostAgentLog, []byte(fmt.Sprintf("\n===== host agent attempt %03d %s =====\n", attempt, time.Now().UTC().Format(time.RFC3339))))
		output, err := runner.RunWithLog(plan.HostAgentBin, args, plan.HostAgentLog)
		if err != nil {
			agentStatus = err
		}
		if runtimeExitExists(config, plan, runner) {
			return agentStatus
		}
		switch agentAttemptState(output, err) {
		case "idle":
			consecutiveIdle++
			if plan.AgentIdleLimit > 0 && consecutiveIdle >= plan.AgentIdleLimit {
				fmt.Fprintf(stdout, "runtime_host_agent_idle_stall idle_attempts=%d limit=%d\n", consecutiveIdle, plan.AgentIdleLimit)
				return fmt.Errorf("runtime run-once stalled after %d consecutive idle agent attempts while runtime exit file was still missing", consecutiveIdle)
			}
		case "completed":
			consecutiveIdle = 0
			attemptsSinceProgress = 0
		}
		if attemptsSinceProgress >= plan.AgentAttempts {
			return fmt.Errorf("runtime run-once did not finish within %d agent attempts after last host-agent progress", plan.AgentAttempts)
		}
		if plan.AgentPollInterval > 0 {
			time.Sleep(plan.AgentPollInterval)
		}
	}
}

func agentAttemptState(output []byte, err error) string {
	if err != nil {
		return "error"
	}
	text := string(output)
	if strings.Contains(text, "agent idle") {
		return "idle"
	}
	if strings.Contains(text, "agent completed ") {
		return "completed"
	}
	return "unknown"
}

func runtimeExitExists(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner) bool {
	_, err := runExternal(runner, "docker", append(plan.ComposePrefix, "exec", "-T", config.RuntimeService, "test", "-f", plan.RuntimeExitFile)...)
	return err == nil
}

func readRuntimeExit(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner) (string, error) {
	output, err := dockerComposeExecOutput(config, plan, runner, "cat", plan.RuntimeExitFile)
	if err != nil {
		return "", err
	}
	exit := strings.TrimSpace(string(output))
	if exit == "" {
		return "", errors.New("runtime exit file is empty")
	}
	return exit, nil
}

func printRuntimeDiagnostics(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer) error {
	fmt.Fprintln(stdout, "--- runtime log ---")
	fmt.Fprint(stdout, string(dockerComposeExecBestEffort(config, plan, runner, "tail", "-n", "220", plan.RuntimeLog)))
	fmt.Fprintln(stdout, "--- server log ---")
	fmt.Fprint(stdout, string(dockerComposeExecBestEffort(config, plan, runner, "tail", "-n", "120", plan.ServerLog)))
	return nil
}

func printRuntimeSuccessTail(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer) error {
	fmt.Fprintln(stdout, "--- runtime log tail ---")
	fmt.Fprint(stdout, string(dockerComposeExecBestEffort(config, plan, runner, "tail", "-n", "160", plan.RuntimeLog)))
	return nil
}

func runRuntimeLoop(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime loop", flag.ContinueOnError)
	flags.SetOutput(stderr)
	interval := flags.String("interval", "60s", "duration between run-once cycles")
	maxCycles := flags.Int("max-cycles", 0, "maximum cycles to run; 0 means forever")
	maxSteps := flags.String("max-steps", "", "maximum runtime steps for each cycle")
	agentAttempts := flags.String("agent-attempts", "", "maximum host agent attempts for each cycle")
	agentPollInterval := flags.String("agent-poll-interval", "", "idle duration between host agent polls during each cycle")
	agentControlPlaneConnectTimeout := flags.String("agent-control-plane-connect-timeout", "", "TCP connect timeout for host agent control plane requests during each cycle")
	agentControlPlaneRequestTimeout := flags.String("agent-control-plane-request-timeout", "", "per-request timeout for host agent control plane requests during each cycle")
	agentControlPlaneRetries := flags.String("agent-control-plane-retries", "", "retry count for transient host agent control plane request failures during each cycle")
	agentControlPlaneRetryDelay := flags.String("agent-control-plane-retry-delay", "", "delay between transient host agent control plane retries during each cycle")
	projectKey := flags.String("project", "", "runtime project key")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	if *maxCycles < 0 {
		return errors.New("--max-cycles must be >= 0")
	}
	sleepDuration, err := time.ParseDuration(*interval)
	if err != nil {
		return fmt.Errorf("parse --interval: %w", err)
	}
	if sleepDuration < 0 {
		return errors.New("--interval must be >= 0")
	}
	if _, err := parseNonNegativeDuration(*agentPollInterval, "agent poll interval"); err != nil {
		return err
	}
	if _, err := parseOptionalPositiveDuration(*agentControlPlaneConnectTimeout, "agent control plane connect timeout"); err != nil {
		return err
	}
	if _, err := parseOptionalPositiveDuration(*agentControlPlaneRequestTimeout, "agent control plane request timeout"); err != nil {
		return err
	}
	if strings.TrimSpace(*agentControlPlaneRetries) != "" {
		if _, err := parseNonNegativeInt(*agentControlPlaneRetries, "agent control plane retries"); err != nil {
			return err
		}
	}
	if _, err := parseNonNegativeDuration(*agentControlPlaneRetryDelay, "agent control plane retry delay"); err != nil {
		return err
	}

	cycle := 0
	for {
		cycle++
		fmt.Fprintf(stdout, "kanban_loop_cycle_start cycle=%d\n", cycle)
		runOnceArgs := buildRunOnceArgs(runtimeRunOnceOverrides{
			MaxSteps:                        *maxSteps,
			AgentAttempts:                   *agentAttempts,
			AgentPollInterval:               *agentPollInterval,
			AgentControlPlaneConnectTimeout: *agentControlPlaneConnectTimeout,
			AgentControlPlaneRequestTimeout: *agentControlPlaneRequestTimeout,
			AgentControlPlaneRetries:        *agentControlPlaneRetries,
			AgentControlPlaneRetryDelay:     *agentControlPlaneRetryDelay,
		})
		if strings.TrimSpace(*projectKey) != "" {
			runOnceArgs = append(runOnceArgs, "--project", strings.TrimSpace(*projectKey))
		}
		if err := runRuntimeRunOnce(runOnceArgs, runner, stdout, stderr); err != nil {
			return fmt.Errorf("runtime loop cycle %d failed: %w", cycle, err)
		}
		fmt.Fprintf(stdout, "kanban_loop_cycle_done cycle=%d\n", cycle)
		if *maxCycles > 0 && cycle >= *maxCycles {
			fmt.Fprintf(stdout, "kanban_loop_finished cycles=%d\n", cycle)
			return nil
		}
		if sleepDuration > 0 {
			time.Sleep(sleepDuration)
		}
	}
}

func buildRunOnceArgs(overrides runtimeRunOnceOverrides) []string {
	args := []string{}
	if strings.TrimSpace(overrides.MaxSteps) != "" {
		args = append(args, "--max-steps", strings.TrimSpace(overrides.MaxSteps))
	}
	if strings.TrimSpace(overrides.AgentAttempts) != "" {
		args = append(args, "--agent-attempts", strings.TrimSpace(overrides.AgentAttempts))
	}
	if strings.TrimSpace(overrides.AgentPollInterval) != "" {
		args = append(args, "--agent-poll-interval", strings.TrimSpace(overrides.AgentPollInterval))
	}
	if strings.TrimSpace(overrides.AgentControlPlaneConnectTimeout) != "" {
		args = append(args, "--agent-control-plane-connect-timeout", strings.TrimSpace(overrides.AgentControlPlaneConnectTimeout))
	}
	if strings.TrimSpace(overrides.AgentControlPlaneRequestTimeout) != "" {
		args = append(args, "--agent-control-plane-request-timeout", strings.TrimSpace(overrides.AgentControlPlaneRequestTimeout))
	}
	if strings.TrimSpace(overrides.AgentControlPlaneRetries) != "" {
		args = append(args, "--agent-control-plane-retries", strings.TrimSpace(overrides.AgentControlPlaneRetries))
	}
	if strings.TrimSpace(overrides.AgentControlPlaneRetryDelay) != "" {
		args = append(args, "--agent-control-plane-retry-delay", strings.TrimSpace(overrides.AgentControlPlaneRetryDelay))
	}
	return args
}

func parseNonNegativeDuration(raw string, label string) (time.Duration, error) {
	if strings.TrimSpace(raw) == "" {
		return 0, nil
	}
	value, err := time.ParseDuration(strings.TrimSpace(raw))
	if err != nil {
		return 0, fmt.Errorf("parse %s: %w", label, err)
	}
	if value < 0 {
		return 0, fmt.Errorf("%s must be >= 0", label)
	}
	return value, nil
}

func parseOptionalPositiveDuration(raw string, label string) (time.Duration, error) {
	if strings.TrimSpace(raw) == "" {
		return 0, nil
	}
	value, err := time.ParseDuration(strings.TrimSpace(raw))
	if err != nil {
		return 0, fmt.Errorf("parse %s: %w", label, err)
	}
	if value <= 0 {
		return 0, fmt.Errorf("%s must be > 0", label)
	}
	return value, nil
}

func parseNonNegativeInt(raw string, label string) (int, error) {
	value, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil {
		return 0, fmt.Errorf("parse %s: %w", label, err)
	}
	if value < 0 {
		return 0, fmt.Errorf("%s must be >= 0", label)
	}
	return value, nil
}

func formatOptionalDuration(value time.Duration) string {
	if value <= 0 {
		return "default"
	}
	return value.String()
}
