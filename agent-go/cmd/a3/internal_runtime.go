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
	"strings"
	"time"
)

const packagedKanbanCLIPath = "/opt/a2o/share/tools/kanban/cli.py"
const packagedKanbanBootstrapPath = "/opt/a2o/share/tools/kanban/bootstrap_soloboard.py"

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
	case "start":
		if err := runRuntimeResume(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "stop":
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
	case "watch-summary":
		if err := runRuntimeWatchSummary(args[1:], runner, stdout, stderr); err != nil {
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
	default:
		fmt.Fprintf(stderr, "unknown runtime subcommand: %s\n", args[0])
		printUsage(stderr)
		return 2
	}
}

type runtimeSchedulerPaths struct {
	Dir         string
	PIDFile     string
	CommandFile string
	LogFile     string
}

func schedulerPaths(config runtimeInstanceConfig) runtimeSchedulerPaths {
	dir := filepath.Join(config.WorkspaceRoot, ".work", "a2o-runtime")
	return runtimeSchedulerPaths{
		Dir:         dir,
		PIDFile:     filepath.Join(dir, "scheduler.pid"),
		CommandFile: filepath.Join(dir, "scheduler.command"),
		LogFile:     filepath.Join(dir, "scheduler.log"),
	}
}

func runRuntimeResume(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime resume", flag.ContinueOnError)
	flags.SetOutput(stderr)
	interval := flags.String("interval", "60s", "duration between scheduler cycles")
	maxSteps := flags.String("max-steps", "", "maximum runtime steps for each cycle")
	agentAttempts := flags.String("agent-attempts", "", "maximum host agent attempts for each cycle")
	agentPollInterval := flags.String("agent-poll-interval", "", "idle duration between host agent polls during each cycle")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	sleepDuration, err := time.ParseDuration(*interval)
	if err != nil {
		return fmt.Errorf("parse --interval: %w", err)
	}
	if sleepDuration < 0 {
		return errors.New("--interval must be >= 0")
	}
	if strings.TrimSpace(*maxSteps) != "" {
		if _, err := parsePositiveInt(*maxSteps, "max steps"); err != nil {
			return err
		}
	}
	if strings.TrimSpace(*agentAttempts) != "" {
		if _, err := parsePositiveInt(*agentAttempts, "agent attempts"); err != nil {
			return err
		}
	}
	if _, err := parseNonNegativeDuration(*agentPollInterval, "agent poll interval"); err != nil {
		return err
	}

	config, _, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	if _, err := buildRuntimeRunOncePlan(effectiveConfig, *maxSteps, *agentAttempts, *agentPollInterval, ""); err != nil {
		return err
	}
	paths := schedulerPaths(effectiveConfig)
	if err := os.MkdirAll(paths.Dir, 0o755); err != nil {
		return fmt.Errorf("create scheduler dir: %w", err)
	}
	if pid, ok, err := readRunningScheduler(paths.PIDFile, runner); err != nil {
		return err
	} else if ok {
		if err := runtimeSchedulerStateCommand(effectiveConfig, runner, "resume-scheduler"); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "runtime_scheduler_resumed pid=%d paused=false pid_file=%s log=%s\n", pid, paths.PIDFile, paths.LogFile)
		fmt.Fprintln(stdout, "describe_task=a2o runtime describe-task <task-ref>")
		return nil
	}
	if err := runtimeSchedulerStateCommand(effectiveConfig, runner, "resume-scheduler"); err != nil {
		return err
	}
	resumed := false
	defer func() {
		if !resumed {
			_ = runtimeSchedulerStateCommand(effectiveConfig, runner, "pause-scheduler")
		}
	}()
	executable, err := os.Executable()
	if err != nil {
		return fmt.Errorf("resolve executable: %w", err)
	}
	loopArgs := []string{"runtime", "loop", "--interval", *interval}
	loopArgs = append(loopArgs, buildRunOnceArgs(*maxSteps, *agentAttempts, *agentPollInterval)...)
	expectedCommand := schedulerExpectedCommand(executable, loopArgs)
	pid, err := runner.StartBackground(executable, loopArgs, paths.LogFile)
	if err != nil {
		return err
	}
	if err := os.WriteFile(paths.CommandFile, []byte(expectedCommand+"\n"), 0o644); err != nil {
		_ = runner.TerminateProcessGroup(pid)
		return fmt.Errorf("write scheduler command file: %w", err)
	}
	if err := os.WriteFile(paths.PIDFile, []byte(fmt.Sprintf("%d\n", pid)), 0o644); err != nil {
		_ = runner.TerminateProcessGroup(pid)
		_ = os.Remove(paths.CommandFile)
		return fmt.Errorf("write scheduler pid file: %w", err)
	}
	resumed = true
	fmt.Fprintf(stdout, "runtime_scheduler_resumed pid_file=%s log=%s paused=false\n", paths.PIDFile, paths.LogFile)
	fmt.Fprintln(stdout, "describe_task=a2o runtime describe-task <task-ref>")
	return nil
}

func runRuntimePause(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime pause", flag.ContinueOnError)
	flags.SetOutput(stderr)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	config, _, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	if err := runtimeSchedulerStateCommand(effectiveConfig, runner, "pause-scheduler"); err != nil {
		return err
	}
	paths := schedulerPaths(effectiveConfig)
	pid, err := readSchedulerPID(paths.PIDFile)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			fmt.Fprintf(stdout, "runtime_scheduler_paused pid_file=%s log=%s running=false\n", paths.PIDFile, paths.LogFile)
			return nil
		}
		return err
	}
	running := schedulerProcessRunning(pid, paths.CommandFile, runner)
	fmt.Fprintf(stdout, "runtime_scheduler_paused pid=%d pid_file=%s log=%s running=%t\n", pid, paths.PIDFile, paths.LogFile, running)
	return nil
}

func runRuntimeStatus(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime status", flag.ContinueOnError)
	flags.SetOutput(stderr)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	config, configPath, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	paths := schedulerPaths(effectiveConfig)
	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", publicInstanceConfigPath(configPath))
	fmt.Fprintf(stdout, "runtime_package=%s\n", effectiveConfig.PackagePath)
	fmt.Fprintf(stdout, "compose_project=%s\n", effectiveConfig.ComposeProject)
	fmt.Fprintf(stdout, "kanban_url=%s\n", kanbanPublicURL(effectiveConfig))
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
		fmt.Fprintf(stdout, "runtime_scheduler_status=stale pid=%d pid_file=%s log=%s\n", pid, paths.PIDFile, paths.LogFile)
	}
	return withComposeEnv(effectiveConfig, func() error {
		printRuntimeSchedulerPauseState(effectiveConfig, runner, stdout)
		printRuntimeServiceStatus(effectiveConfig, runner, stdout)
		printRuntimeImageStatus(&effectiveConfig, runner, stdout)
		printLatestRuntimeSummary(effectiveConfig, runner, stdout)
		return nil
	})
}

func runtimeSchedulerStateCommand(config runtimeInstanceConfig, runner commandRunner, command string) error {
	plan, err := buildRuntimeRunOncePlan(config, "", "", "", "")
	if err != nil {
		return err
	}
	_, err = dockerComposeExecOutput(config, plan, runner, "a3", command, "--storage-backend", "json", "--storage-dir", plan.StorageDir)
	return err
}

func printRuntimeSchedulerPauseState(config runtimeInstanceConfig, runner commandRunner, stdout io.Writer) {
	plan, err := buildRuntimeRunOncePlan(config, "", "", "", "")
	if err != nil {
		fmt.Fprintf(stdout, "runtime_scheduler_pause status=unavailable reason=%s\n", singleLine(err.Error()))
		return
	}
	output, err := dockerComposeExecOutput(config, plan, runner, "a3", "show-scheduler-state", "--storage-backend", "json", "--storage-dir", plan.StorageDir)
	if err != nil {
		fmt.Fprintf(stdout, "runtime_scheduler_pause status=unavailable reason=%s\n", singleLine(err.Error()))
		return
	}
	summary := strings.TrimSpace(string(output))
	if summary == "" {
		fmt.Fprintln(stdout, "runtime_scheduler_pause status=unavailable reason=empty")
		return
	}
	if strings.HasPrefix(summary, "scheduler ") {
		summary = "runtime_" + summary
	}
	fmt.Fprintln(stdout, sanitizePublicCommand(summary))
}

func runRuntimeImageDigest(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime image-digest", flag.ContinueOnError)
	flags.SetOutput(stderr)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	config, _, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	return withComposeEnv(effectiveConfig, func() error {
		report := runtimeImageDigestReport(&effectiveConfig, runner)
		printRuntimeImageDigestReport(report, stdout)
		return nil
	})
}

func printRuntimeServiceStatus(config runtimeInstanceConfig, runner commandRunner, stdout io.Writer) {
	for _, check := range []struct {
		name    string
		service string
	}{
		{name: "runtime_container", service: config.RuntimeService},
		{name: "kanban_service", service: "soloboard"},
	} {
		output, err := runExternal(runner, "docker", append(composeArgs(config), "ps", "--status", "running", "-q", check.service)...)
		if err != nil {
			fmt.Fprintf(stdout, "runtime_status_check name=%s status=blocked detail=%s\n", check.name, singleLine(err.Error()))
			continue
		}
		containerID := strings.TrimSpace(string(output))
		if containerID == "" {
			fmt.Fprintf(stdout, "runtime_status_check name=%s status=stopped action=run a2o runtime up\n", check.name)
			continue
		}
		fmt.Fprintf(stdout, "runtime_status_check name=%s status=running container=%s\n", check.name, containerID)
	}
}

func printRuntimeImageStatus(config *runtimeInstanceConfig, runner commandRunner, stdout io.Writer) {
	report := runtimeImageDigestReport(config, runner)
	if report.ConfiguredDigest != "" {
		printRuntimeImageDigestReport(report, stdout)
		return
	}
	fmt.Fprintln(stdout, "runtime_image_digest=unavailable action=pull or build runtime image")
}

type runtimeImageReport struct {
	ConfiguredRef     string
	ConfiguredDigest  string
	LocalLatestRef    string
	LocalLatestDigest string
	RunningContainer  string
	RunningImageID    string
	RunningDigest     string
}

func runtimeImageDigestReport(config *runtimeInstanceConfig, runner commandRunner) runtimeImageReport {
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	configuredRef := runtimeImageReference(config)
	report := runtimeImageReport{
		ConfiguredRef:    configuredRef,
		ConfiguredDigest: runtimeImageDigest(&effectiveConfig, runner),
		LocalLatestRef:   latestRuntimeImageReference(configuredRef),
	}
	if report.LocalLatestRef != "" {
		report.LocalLatestDigest = imageDigestForReference(report.LocalLatestRef, runner)
	}
	report.RunningContainer, report.RunningImageID, report.RunningDigest = runningRuntimeImageDigest(effectiveConfig, runner)
	return report
}

func printRuntimeImageDigestReport(report runtimeImageReport, stdout io.Writer) {
	fmt.Fprintf(stdout, "runtime_image_digest=%s\n", valueOrUnavailable(report.ConfiguredDigest))
	fmt.Fprintf(stdout, "runtime_image_pinned_ref=%s\n", valueOrUnavailable(report.ConfiguredRef))
	fmt.Fprintf(stdout, "runtime_image_pinned_digest=%s\n", valueOrUnavailable(report.ConfiguredDigest))
	fmt.Fprintf(stdout, "runtime_image_local_latest_ref=%s\n", valueOrUnavailable(report.LocalLatestRef))
	fmt.Fprintf(stdout, "runtime_image_local_latest_digest=%s\n", valueOrUnavailable(report.LocalLatestDigest))
	if report.RunningContainer == "" {
		fmt.Fprintln(stdout, "runtime_image_running_container=unavailable")
	} else {
		fmt.Fprintf(stdout, "runtime_image_running_container=%s image_id=%s digest=%s\n", report.RunningContainer, valueOrUnavailable(report.RunningImageID), valueOrUnavailable(report.RunningDigest))
	}
	fmt.Fprintf(stdout, "runtime_image_latest_status=%s action=%s\n", runtimeImageComparisonStatus(report.ConfiguredDigest, report.LocalLatestDigest), runtimeImageLatestAction(report.ConfiguredDigest, report.LocalLatestDigest, report.LocalLatestRef))
	fmt.Fprintf(stdout, "runtime_image_running_status=%s action=%s\n", runtimeImageComparisonStatus(report.ConfiguredDigest, report.RunningDigest), runtimeImageRunningAction(report.ConfiguredDigest, report.RunningDigest))
}

func runtimeImageComparisonStatus(expected string, actual string) string {
	expectedDigest := digestIdentity(expected)
	actualDigest := digestIdentity(actual)
	if expectedDigest == "" || actualDigest == "" {
		return "unknown"
	}
	if expectedDigest == actualDigest {
		return "current"
	}
	return "mismatch"
}

func runtimeImageLatestAction(configuredDigest string, latestDigest string, latestRef string) string {
	switch runtimeImageComparisonStatus(configuredDigest, latestDigest) {
	case "current":
		return "none"
	case "mismatch":
		return "validate local latest, then update the package runtime image pin if you want this version"
	default:
		if latestRef == "" {
			return "configure A2O_RUNTIME_IMAGE, pull or inspect the configured runtime image, then rerun a2o runtime image-digest"
		}
		return "pull " + latestRef + " or inspect the configured runtime image, then rerun a2o runtime image-digest"
	}
}

func runtimeImageRunningAction(configuredDigest string, runningDigest string) string {
	switch runtimeImageComparisonStatus(configuredDigest, runningDigest) {
	case "current":
		return "none"
	case "mismatch":
		return "restart runtime with a2o runtime up after confirming the desired pinned digest"
	default:
		return "run a2o runtime up, then rerun a2o runtime status"
	}
}

func digestIdentity(reference string) string {
	parts := strings.SplitN(strings.TrimSpace(reference), "@", 2)
	if len(parts) == 2 {
		return parts[1]
	}
	return ""
}

func valueOrUnavailable(value string) string {
	if strings.TrimSpace(value) == "" {
		return "unavailable"
	}
	return value
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
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	config, _, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
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
		if _, err := runExternal(runner, "docker", append(composePrefix, "up", "-d", effectiveConfig.RuntimeService, "soloboard")...); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "runtime_up compose_project=%s package=%s\n", effectiveConfig.ComposeProject, effectiveConfig.PackagePath)
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
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	config, configPath, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", publicInstanceConfigPath(configPath))
	fmt.Fprintf(stdout, "package=%s\n", effectiveConfig.PackagePath)
	fmt.Fprintf(stdout, "compose_project=%s\n", effectiveConfig.ComposeProject)
	for _, check := range []struct {
		name    string
		service string
	}{
		{name: "runtime_container", service: effectiveConfig.RuntimeService},
		{name: "kanban_service", service: "soloboard"},
	} {
		output, err := runExternal(runner, "docker", append(composeArgs(effectiveConfig), "ps", "--status", "running", "-q", check.service)...)
		if err != nil {
			return err
		}
		containerID := strings.TrimSpace(string(output))
		if containerID == "" {
			fmt.Fprintf(stdout, "runtime_doctor_check name=%s status=blocked action=run a2o runtime up\n", check.name)
			continue
		}
		fmt.Fprintf(stdout, "runtime_doctor_check name=%s status=ok container=%s\n", check.name, containerID)
	}
	return nil
}

func runRuntimeDown(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime down", flag.ContinueOnError)
	flags.SetOutput(stderr)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	config, _, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	if _, err := runExternal(runner, "docker", append(composeArgs(*config), "down")...); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "runtime_down compose_project=%s\n", config.ComposeProject)
	return nil
}

func runRuntimeCommandPlan(args []string, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime command-plan", flag.ContinueOnError)
	flags.SetOutput(stderr)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	config, configPath, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", publicInstanceConfigPath(configPath))
	fmt.Fprintln(stdout, "kanban_up=a2o kanban up")
	fmt.Fprintln(stdout, "kanban_doctor=a2o kanban doctor")
	fmt.Fprintf(stdout, "kanban_url=%s\n", kanbanPublicURL(*config))
	fmt.Fprintln(stdout, "runtime_up=a2o runtime up")
	fmt.Fprintln(stdout, "agent_install=a2o agent install")
	return nil
}

func runRuntimeDescribeTask(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime describe-task", flag.ContinueOnError)
	flags.SetOutput(stderr)
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

	config, configPath, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	return withComposeEnv(effectiveConfig, func() error {
		plan, err := buildRuntimeDescribeTaskPlan(effectiveConfig)
		if err != nil {
			return err
		}
		fmt.Fprintf(stdout, "describe_task task_ref=%s\n", taskRef)
		fmt.Fprintf(stdout, "runtime_instance_config=%s\n", publicInstanceConfigPath(configPath))
		fmt.Fprintf(stdout, "package=%s\n", effectiveConfig.PackagePath)
		fmt.Fprintf(stdout, "compose_project=%s\n", effectiveConfig.ComposeProject)
		fmt.Fprintf(stdout, "kanban_project=%s kanban_url=%s\n", plan.KanbanProject, kanbanPublicURL(effectiveConfig))
		fmt.Fprintf(stdout, "runtime_storage=internal-managed project_config=%s surface_source=project-package\n", plan.ManifestPath)
		fmt.Fprintf(stdout, "operator_next=a2o runtime describe-task %s\n", taskRef)

		runRef := ""
		taskOutput, err := runtimeDescribeSectionOutput(effectiveConfig, plan, runner, "task", "a3", "show-task", "--storage-backend", "json", "--storage-dir", plan.StorageDir, taskRef)
		if err != nil {
			fmt.Fprintf(stdout, "describe_section name=task status=blocked action=run a2o runtime run-once or verify task ref detail=%s\n", singleLine(err.Error()))
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

func runRuntimeResetTask(args []string, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime reset-task", flag.ContinueOnError)
	flags.SetOutput(stderr)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 1 {
		return fmt.Errorf("usage: a2o runtime reset-task TASK_REF")
	}
	taskRef := strings.TrimSpace(flags.Arg(0))
	if taskRef == "" {
		return fmt.Errorf("task ref is required")
	}

	config, configPath, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	plan, err := buildRuntimeRunOncePlan(effectiveConfig, "", "", "", "")
	if err != nil {
		return err
	}

	fmt.Fprintf(stdout, "reset_task_plan task_ref=%s mode=dry-run\n", taskRef)
	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", publicInstanceConfigPath(configPath))
	fmt.Fprintf(stdout, "kanban_project=%s kanban_url=%s\n", plan.KanbanProject, kanbanPublicURL(effectiveConfig))
	fmt.Fprintf(stdout, "runtime_storage=internal-managed project_config=%s surface_source=project-package\n", plan.ManifestPath)
	fmt.Fprintf(stdout, "runtime_logs runtime=%s server=%s host_agent=%s\n", plan.RuntimeLog, plan.ServerLog, plan.HostAgentLog)
	fmt.Fprintf(stdout, "affected_artifact kind=kanban task_ref=%s action=inspect task, comments, and blocked label with describe-task before changing anything\n", taskRef)
	fmt.Fprintln(stdout, "affected_artifact kind=runtime_state file=tasks.json action=preserve; scheduler resyncs kanban task state")
	fmt.Fprintln(stdout, "affected_artifact kind=runtime_state file=runs.json action=preserve; rerun history and blocked diagnosis stay inspectable")
	fmt.Fprintln(stdout, "affected_artifact kind=evidence directory=evidence action=preserve for review and blocked diagnosis")
	fmt.Fprintln(stdout, "affected_artifact kind=blocked_diagnosis directory=blocked_diagnoses action=preserve until the rerun is accepted")
	fmt.Fprintf(stdout, "affected_artifact kind=workspace path=%s action=quarantine or remove only after preserving needed manual changes\n", plan.WorkspaceRoot)
	fmt.Fprintf(stdout, "affected_artifact kind=branch namespace=%s action=inspect task branches and remove stale branches only after preserving needed commits\n", plan.BranchNamespace)
	fmt.Fprintf(stdout, "recovery_step 1 command=a2o runtime describe-task %s purpose=read blocked reason, run, evidence, kanban comments, and logs\n", taskRef)
	fmt.Fprintln(stdout, "recovery_step 2 command=a2o runtime watch-summary purpose=confirm the scheduler sees the task as blocked and no sibling task is still running")
	fmt.Fprintln(stdout, "recovery_step 3 action=fix_root_cause purpose=repair executor config, dirty repo, missing command, merge conflict, or product failure reported by describe-task")
	fmt.Fprintln(stdout, "recovery_step 4 action=preserve_manual_changes purpose=commit, patch, or discard any useful changes in the listed workspace and branches")
	fmt.Fprintln(stdout, "recovery_step 5 action=clear_blocked_label purpose=remove the kanban blocked label only after the root cause is fixed")
	fmt.Fprintln(stdout, "recovery_step 6 command=a2o runtime run-once purpose=let A2O resync kanban state and start a fresh run")
	fmt.Fprintln(stdout, "apply_supported=false")
	return nil
}

func runRuntimeWatchSummary(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime watch-summary", flag.ContinueOnError)
	flags.SetOutput(stderr)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	config, _, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	return withComposeEnv(effectiveConfig, func() error {
		plan, err := buildRuntimeDescribeTaskPlan(effectiveConfig)
		if err != nil {
			return err
		}
		output, err := runtimeDescribeSectionOutput(effectiveConfig, plan, runner, "watch_summary", runtimeWatchSummaryArgs(plan)...)
		if err != nil {
			return err
		}
		if strings.TrimSpace(output) == "" {
			return nil
		}
		fmt.Fprintln(stdout, output)
		return nil
	})
}

func runRuntimeLogs(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime logs", flag.ContinueOnError)
	flags.SetOutput(stderr)
	follow := flags.Bool("follow", false, "follow the current phase live log while the task is running")
	flags.BoolVar(follow, "f", false, "follow the current phase live log while the task is running")
	pollInterval := flags.Duration("poll-interval", time.Second, "poll interval for --follow")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 1 {
		return fmt.Errorf("usage: a2o runtime logs TASK_REF [--follow]")
	}
	taskRef := strings.TrimSpace(flags.Arg(0))
	if taskRef == "" {
		return fmt.Errorf("task ref is required")
	}

	config, _, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	return withComposeEnv(effectiveConfig, func() error {
		plan, err := buildRuntimeDescribeTaskPlan(effectiveConfig)
		if err != nil {
			return err
		}
		printedArtifacts := map[string]bool{}
		offsets := map[string]int64{}
		lastLiveKey := ""
		for {
			manifest, err := runtimeTaskLogManifest(effectiveConfig, plan, runner, taskRef)
			if err != nil {
				return err
			}
			for _, item := range manifest.CompletedArtifacts {
				if printedArtifacts[item.ArtifactID] {
					continue
				}
				if err := printRuntimeArtifactSection(effectiveConfig, plan, runner, stdout, item.Phase, item.ArtifactID, item.Mode); err != nil {
					return err
				}
				printedArtifacts[item.ArtifactID] = true
			}
			if manifest.Active && manifest.CurrentRunRef != "" && manifest.CurrentPhase != "" {
				livePath := plan.preferredLiveLogPath(taskRef, manifest.CurrentPhase)
				liveKey := manifest.CurrentRunRef + "|" + manifest.CurrentPhase + "|" + manifest.LiveMode + "|" + livePath
				if liveKey != lastLiveKey {
					offsets[livePath] = 0
					fmt.Fprintf(stdout, "=== phase: %s (%s) task=%s run=%s source=%s:%s ===\n", manifest.CurrentPhase, manifest.LiveMode, taskRef, manifest.CurrentRunRef, valueOrUnavailable(manifest.SourceType), valueOrUnavailable(manifest.SourceRef))
					lastLiveKey = liveKey
				}
				nextOffset, err := printFileDelta(stdout, livePath, offsets[livePath])
				if err != nil {
					return err
				}
				offsets[livePath] = nextOffset
			}
			if !*follow || !manifest.Active || manifest.CurrentRunRef == "" || manifest.CurrentPhase == "" {
				return nil
			}
			time.Sleep(*pollInterval)
		}
	})
}

func runRuntimeShowArtifact(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime show-artifact", flag.ContinueOnError)
	flags.SetOutput(stderr)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 1 {
		return fmt.Errorf("usage: a2o runtime show-artifact ARTIFACT_ID")
	}
	artifactID := strings.TrimSpace(flags.Arg(0))
	if artifactID == "" {
		return fmt.Errorf("artifact id is required")
	}

	config, _, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	return withComposeEnv(effectiveConfig, func() error {
		plan, err := buildRuntimeDescribeTaskPlan(effectiveConfig)
		if err != nil {
			return err
		}
		output, err := runtimeDescribeSectionOutput(effectiveConfig, plan, runner, "agent_artifact", "a3", "agent-artifact-read", "--storage-dir", plan.StorageDir, artifactID)
		if err != nil {
			return err
		}
		if strings.TrimSpace(output) == "" {
			return nil
		}
		fmt.Fprintln(stdout, output)
		return nil
	})
}

func runRuntimeClearLogs(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime clear-logs", flag.ContinueOnError)
	flags.SetOutput(stderr)
	taskRef := flags.String("task-ref", "", "clear durable logs for one task")
	runRef := flags.String("run-ref", "", "clear durable logs for one run")
	phase := flags.String("phase", "", "limit clear to one phase")
	role := flags.String("role", "", "limit clear to one role")
	allAnalysis := flags.Bool("all-analysis", false, "clear all persisted analysis logs")
	apply := flags.Bool("apply", false, "apply deletion; defaults to dry-run")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *taskRef == "" && *runRef == "" && !*allAnalysis {
		return fmt.Errorf("usage: a2o runtime clear-logs (--task-ref TASK_REF | --run-ref RUN_REF | --all-analysis) [--phase PHASE] [--role ROLE] [--apply]")
	}

	config, _, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	return withComposeEnv(effectiveConfig, func() error {
		plan, err := buildRuntimeDescribeTaskPlan(effectiveConfig)
		if err != nil {
			return err
		}
		commandArgs := []string{"a3", "clear-runtime-logs", "--storage-backend", "json", "--storage-dir", plan.StorageDir}
		if *taskRef != "" {
			commandArgs = append(commandArgs, "--task-ref", *taskRef)
		}
		if *runRef != "" {
			commandArgs = append(commandArgs, "--run-ref", *runRef)
		}
		if *phase != "" {
			commandArgs = append(commandArgs, "--phase", *phase)
		}
		if *role != "" {
			commandArgs = append(commandArgs, "--role", *role)
		}
		if *allAnalysis {
			commandArgs = append(commandArgs, "--all-analysis")
		}
		if *apply {
			commandArgs = append(commandArgs, "--apply")
		}
		output, err := runtimeDescribeSectionOutput(effectiveConfig, plan, runner, "runtime_log_clear", commandArgs...)
		if err != nil {
			return err
		}
		if strings.TrimSpace(output) != "" {
			fmt.Fprintln(stdout, output)
		}
		return nil
	})
}

func runRuntimeRunOnce(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime run-once", flag.ContinueOnError)
	flags.SetOutput(stderr)
	maxSteps := flags.String("max-steps", "", "maximum runtime steps for this cycle")
	agentAttempts := flags.String("agent-attempts", "", "maximum host agent attempts for this cycle")
	agentPollInterval := flags.String("agent-poll-interval", "", "idle duration between host agent polls for this cycle")
	projectConfig := flags.String("project-config", "", "explicit project config file, for example project-test.yaml")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	config, configPath, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")

	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", publicInstanceConfigPath(configPath))
	fmt.Fprintln(stdout, "describe_task=a2o runtime describe-task <task-ref>")
	return withEnv(runtimeRunOnceEnv(effectiveConfig, *maxSteps, *agentAttempts), func() error {
		return runGenericRuntimeRunOnce(effectiveConfig, *maxSteps, *agentAttempts, *agentPollInterval, *projectConfig, runner, stdout)
	})
}

type runtimeRunOncePlan struct {
	ComposePrefix        []string
	MaxSteps             string
	AgentAttempts        int
	AgentPollInterval    time.Duration
	AgentPort            string
	AgentInternalPort    string
	StorageDir           string
	HostRootDir          string
	HostRoot             string
	WorkspaceRoot        string
	HostAgentBin         string
	HostAgentSource      string
	HostAgentTarget      string
	HostAgentLog         string
	LiveLogRoot          string
	AIRawLogRoot         string
	LauncherConfigPath   string
	LauncherConfig       map[string]any
	ServerLog            string
	RuntimeLog           string
	RuntimeExitFile      string
	RuntimePIDFile       string
	ServerPIDFile        string
	PresetDir            string
	ManifestPath         string
	SoloBoardInternalURL string
	LiveRef              string
	AgentEnv             []string
	AgentSourcePaths     []string
	AgentRequiredBins    []string
	AgentSourceAliases   []string
	KanbanProject        string
	KanbanStatus         string
	KanbanRepoLabels     []string
	RepoSources          []string
	LocalSourceAliases   []string
	WorkerCommand        string
	WorkerArgs           []string
	JobTimeoutSeconds    string
	BranchNamespace      string
}

func runGenericRuntimeRunOnce(config runtimeInstanceConfig, maxSteps string, agentAttempts string, agentPollInterval string, projectConfig string, runner commandRunner, stdout io.Writer) error {
	plan, err := buildRuntimeRunOncePlan(config, maxSteps, agentAttempts, agentPollInterval, projectConfig)
	if err != nil {
		return err
	}
	return withComposeEnv(config, func() error {
		fmt.Fprintf(stdout, "kanban_run_once=generic\n")
		if err := cleanupLegacyRuntimeServiceOrphans(config, runner, stdout); err != nil {
			return err
		}
		if _, err := runExternal(runner, "docker", append(plan.ComposePrefix, "up", "-d", config.RuntimeService, "soloboard")...); err != nil {
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

func buildRuntimeRunOncePlan(config runtimeInstanceConfig, maxSteps string, agentAttempts string, agentPollInterval string, projectConfig string) (runtimeRunOncePlan, error) {
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
	hostRoot := envDefaultCompat("A2O_RUNTIME_RUN_ONCE_HOST_ROOT", "A3_RUNTIME_RUN_ONCE_HOST_ROOT", envDefaultCompat("A2O_RUNTIME_SCHEDULER_HOST_ROOT", "A3_RUNTIME_SCHEDULER_HOST_ROOT", filepath.Join(hostRootDir, runtimeHostAgentRelativePath)))
	defaultWorkspaceRoot := filepath.Join(hostRoot, "workspaces")
	if strings.TrimSpace(packageConfig.AgentWorkspaceRoot) != "" {
		defaultWorkspaceRoot = resolvePackagePath(hostRootDir, packageConfig.AgentWorkspaceRoot)
	}
	workspaceRoot := envDefaultCompat("A2O_RUNTIME_RUN_ONCE_AGENT_WORKSPACE_ROOT", "A3_RUNTIME_RUN_ONCE_AGENT_WORKSPACE_ROOT", envDefaultCompat("A2O_RUNTIME_SCHEDULER_AGENT_WORKSPACE_ROOT", "A3_RUNTIME_SCHEDULER_AGENT_WORKSPACE_ROOT", defaultWorkspaceRoot))
	hostAgentBin := envDefaultCompat("A2O_HOST_AGENT_BIN", "A3_HOST_AGENT_BIN", resolveDefaultHostAgentBin(config, hostRootDir))
	defaultAgentAttempts := envDefaultValue(packageConfig.AgentAttempts, "220")
	defaultAgentPollInterval := envDefaultValue(packageConfig.AgentPollInterval, "1s")
	agentAttemptCount, err := parsePositiveInt(envDefaultValue(agentAttempts, envDefaultCompat("A2O_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS", "A3_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS", envDefaultCompat("A2O_RUNTIME_SCHEDULER_AGENT_ATTEMPTS", "A3_RUNTIME_SCHEDULER_AGENT_ATTEMPTS", defaultAgentAttempts))), "agent attempts")
	if err != nil {
		return runtimeRunOncePlan{}, err
	}
	agentPollDuration, err := parseNonNegativeDuration(envDefaultValue(agentPollInterval, envDefaultCompat("A2O_RUNTIME_RUN_ONCE_AGENT_POLL_INTERVAL", "A3_RUNTIME_RUN_ONCE_AGENT_POLL_INTERVAL", envDefaultCompat("A2O_RUNTIME_SCHEDULER_AGENT_POLL_INTERVAL", "A3_RUNTIME_SCHEDULER_AGENT_POLL_INTERVAL", defaultAgentPollInterval))), "agent poll interval")
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
		requiredBins = []string{"git", "node"}
	}
	defaultMaxSteps := envDefaultValue(packageConfig.MaxSteps, "16")
	defaultLiveRef := envDefaultValue(packageConfig.LiveRef, "refs/heads/feature/prototype")
	defaultKanbanProject := packageConfig.KanbanProject
	defaultKanbanStatus := envDefaultValue(packageConfig.KanbanStatus, "To do")
	launcherConfigPath := envDefaultCompat("A2O_WORKER_LAUNCHER_CONFIG_PATH", "A3_WORKER_LAUNCHER_CONFIG_PATH", filepath.Join(hostRoot, "launcher.json"))
	if len(packageConfig.Executor) == 0 {
		return runtimeRunOncePlan{}, fmt.Errorf("project.yaml runtime.phases.implementation.executor.command is required for packaged a2o-agent worker execution")
	}
	return runtimeRunOncePlan{
		ComposePrefix:        composeArgs(config),
		MaxSteps:             envDefaultValue(maxSteps, envDefaultCompat("A2O_RUNTIME_RUN_ONCE_MAX_STEPS", "A3_RUNTIME_RUN_ONCE_MAX_STEPS", envDefaultCompat("A2O_RUNTIME_SCHEDULER_MAX_STEPS", "A3_RUNTIME_SCHEDULER_MAX_STEPS", defaultMaxSteps))),
		AgentAttempts:        agentAttemptCount,
		AgentPollInterval:    agentPollDuration,
		AgentPort:            envDefaultCompat("A2O_BUNDLE_AGENT_PORT", "A3_BUNDLE_AGENT_PORT", envDefaultValue(config.AgentPort, "7393")),
		AgentInternalPort:    envDefaultCompat("A2O_RUNTIME_RUN_ONCE_AGENT_INTERNAL_PORT", "A3_RUNTIME_RUN_ONCE_AGENT_INTERNAL_PORT", envDefaultCompat("A2O_RUNTIME_SCHEDULER_AGENT_INTERNAL_PORT", "A3_RUNTIME_SCHEDULER_AGENT_INTERNAL_PORT", "7393")),
		StorageDir:           envDefaultCompat("A2O_BUNDLE_STORAGE_DIR", "A3_BUNDLE_STORAGE_DIR", envDefaultValue(config.StorageDir, "/var/lib/a2o/a2o-runtime")),
		HostRootDir:          hostRootDir,
		HostRoot:             hostRoot,
		WorkspaceRoot:        workspaceRoot,
		HostAgentBin:         hostAgentBin,
		HostAgentSource:      envDefaultCompat("A2O_RUNTIME_RUN_ONCE_AGENT_SOURCE", "A3_RUNTIME_RUN_ONCE_AGENT_SOURCE", envDefaultCompat("A2O_RUNTIME_SCHEDULER_AGENT_SOURCE", "A3_RUNTIME_SCHEDULER_AGENT_SOURCE", "runtime-image")),
		HostAgentTarget:      target,
		HostAgentLog:         envDefaultCompat("A2O_RUNTIME_RUN_ONCE_HOST_AGENT_LOG", "A3_RUNTIME_RUN_ONCE_HOST_AGENT_LOG", envDefaultCompat("A2O_RUNTIME_SCHEDULER_HOST_AGENT_LOG", "A3_RUNTIME_SCHEDULER_HOST_AGENT_LOG", filepath.Join(hostRoot, "agent.log"))),
		LiveLogRoot:          envDefaultCompat("A2O_AGENT_LIVE_LOG_ROOT", "A3_AGENT_LIVE_LOG_ROOT", filepath.Join(hostRoot, "live-logs")),
		AIRawLogRoot:         envDefaultCompat("A2O_AGENT_AI_RAW_LOG_ROOT", "A3_AGENT_AI_RAW_LOG_ROOT", filepath.Join(hostRoot, "ai-raw-logs")),
		LauncherConfigPath:   launcherConfigPath,
		LauncherConfig:       packageConfig.Executor,
		ServerLog:            envDefaultCompat("A2O_RUNTIME_RUN_ONCE_SERVER_LOG", "A3_RUNTIME_RUN_ONCE_SERVER_LOG", envDefaultCompat("A2O_RUNTIME_SCHEDULER_SERVER_LOG", "A3_RUNTIME_SCHEDULER_SERVER_LOG", "/tmp/a2o-runtime-run-once-agent-server.log")),
		RuntimeLog:           envDefaultCompat("A2O_RUNTIME_RUN_ONCE_LOG", "A3_RUNTIME_RUN_ONCE_LOG", envDefaultCompat("A2O_RUNTIME_SCHEDULER_LOG", "A3_RUNTIME_SCHEDULER_LOG", "/tmp/a2o-runtime-run-once.log")),
		RuntimeExitFile:      envDefaultCompat("A2O_RUNTIME_RUN_ONCE_EXIT_FILE", "A3_RUNTIME_RUN_ONCE_EXIT_FILE", envDefaultCompat("A2O_RUNTIME_SCHEDULER_EXIT_FILE", "A3_RUNTIME_SCHEDULER_EXIT_FILE", "/tmp/a2o-runtime-run-once.exit")),
		RuntimePIDFile:       envDefaultCompat("A2O_RUNTIME_RUN_ONCE_PID_FILE", "A3_RUNTIME_RUN_ONCE_PID_FILE", envDefaultCompat("A2O_RUNTIME_SCHEDULER_PID_FILE", "A3_RUNTIME_SCHEDULER_PID_FILE", "/tmp/a2o-runtime-run-once.pid")),
		ServerPIDFile:        envDefaultCompat("A2O_RUNTIME_RUN_ONCE_SERVER_PID_FILE", "A3_RUNTIME_RUN_ONCE_SERVER_PID_FILE", envDefaultCompat("A2O_RUNTIME_SCHEDULER_SERVER_PID_FILE", "A3_RUNTIME_SCHEDULER_SERVER_PID_FILE", "/tmp/a2o-runtime-run-once-agent-server.pid")),
		PresetDir:            envDefaultCompat("A2O_RUNTIME_RUN_ONCE_PRESET_DIR", "A3_RUNTIME_RUN_ONCE_PRESET_DIR", envDefaultCompat("A2O_RUNTIME_SCHEDULER_PRESET_DIR", "A3_RUNTIME_SCHEDULER_PRESET_DIR", "/tmp/a3-engine/config/presets")),
		ManifestPath:         projectConfigPath,
		SoloBoardInternalURL: kanbanInternalURL(),
		LiveRef:              envDefaultCompat("A2O_RUNTIME_RUN_ONCE_LIVE_REF", "A3_RUNTIME_RUN_ONCE_LIVE_REF", envDefaultCompat("A2O_RUNTIME_SCHEDULER_LIVE_REF", "A3_RUNTIME_SCHEDULER_LIVE_REF", defaultLiveRef)),
		AgentEnv: []string{
			"A2O_ROOT_DIR=" + hostRootDir,
			"A2O_WORKER_LAUNCHER_CONFIG_PATH=" + launcherConfigPath,
			"A2O_AGENT_LIVE_LOG_ROOT=" + envDefaultCompat("A2O_AGENT_LIVE_LOG_ROOT", "A3_AGENT_LIVE_LOG_ROOT", filepath.Join(hostRoot, "live-logs")),
			"A2O_AGENT_AI_RAW_LOG_ROOT=" + envDefaultCompat("A2O_AGENT_AI_RAW_LOG_ROOT", "A3_AGENT_AI_RAW_LOG_ROOT", filepath.Join(hostRoot, "ai-raw-logs")),
			"A3_MAVEN_WORKSPACE_BOOTSTRAP_MODE=" + envDefaultCompat("A2O_RUNTIME_RUN_ONCE_MAVEN_WORKSPACE_BOOTSTRAP_MODE", "A3_RUNTIME_RUN_ONCE_MAVEN_WORKSPACE_BOOTSTRAP_MODE", envDefaultCompat("A2O_RUNTIME_SCHEDULER_MAVEN_WORKSPACE_BOOTSTRAP_MODE", "A3_RUNTIME_SCHEDULER_MAVEN_WORKSPACE_BOOTSTRAP_MODE", "empty")),
		},
		AgentSourcePaths:   envDefaultListCompat("A2O_RUNTIME_RUN_ONCE_AGENT_SOURCE_PATHS", "A3_RUNTIME_RUN_ONCE_AGENT_SOURCE_PATHS", "A2O_RUNTIME_SCHEDULER_AGENT_SOURCE_PATHS", "A3_RUNTIME_SCHEDULER_AGENT_SOURCE_PATHS", agentSourcePaths),
		AgentRequiredBins:  envDefaultListCompat("A2O_RUNTIME_RUN_ONCE_AGENT_REQUIRED_BINS", "A3_RUNTIME_RUN_ONCE_AGENT_REQUIRED_BINS", "A2O_RUNTIME_SCHEDULER_AGENT_REQUIRED_BINS", "A3_RUNTIME_SCHEDULER_AGENT_REQUIRED_BINS", requiredBins),
		AgentSourceAliases: envDefaultListCompat("A2O_RUNTIME_RUN_ONCE_AGENT_SOURCE_ALIASES", "A3_RUNTIME_RUN_ONCE_AGENT_SOURCE_ALIASES", "A2O_RUNTIME_SCHEDULER_AGENT_SOURCE_ALIASES", "A3_RUNTIME_SCHEDULER_AGENT_SOURCE_ALIASES", agentSourceAliases),
		KanbanProject:      envDefaultCompat("A2O_RUNTIME_RUN_ONCE_KANBAN_PROJECT", "A3_RUNTIME_RUN_ONCE_KANBAN_PROJECT", envDefaultCompat("A2O_RUNTIME_SCHEDULER_KANBAN_PROJECT", "A3_RUNTIME_SCHEDULER_KANBAN_PROJECT", defaultKanbanProject)),
		KanbanStatus:       envDefaultCompat("A2O_RUNTIME_RUN_ONCE_KANBAN_STATUS", "A3_RUNTIME_RUN_ONCE_KANBAN_STATUS", envDefaultCompat("A2O_RUNTIME_SCHEDULER_KANBAN_STATUS", "A3_RUNTIME_SCHEDULER_KANBAN_STATUS", defaultKanbanStatus)),
		KanbanRepoLabels:   envDefaultListCompat("A2O_RUNTIME_RUN_ONCE_KANBAN_REPO_LABELS", "A3_RUNTIME_RUN_ONCE_KANBAN_REPO_LABELS", "A2O_RUNTIME_SCHEDULER_KANBAN_REPO_LABELS", "A3_RUNTIME_SCHEDULER_KANBAN_REPO_LABELS", repoLabels),
		RepoSources:        envDefaultListCompat("A2O_RUNTIME_RUN_ONCE_REPO_SOURCES", "A3_RUNTIME_RUN_ONCE_REPO_SOURCES", "A2O_RUNTIME_SCHEDULER_REPO_SOURCES", "A3_RUNTIME_SCHEDULER_REPO_SOURCES", repoSources),
		LocalSourceAliases: envDefaultListCompat("A2O_RUNTIME_RUN_ONCE_LOCAL_SOURCE_ALIASES", "A3_RUNTIME_RUN_ONCE_LOCAL_SOURCE_ALIASES", "A2O_RUNTIME_SCHEDULER_LOCAL_SOURCE_ALIASES", "A3_RUNTIME_SCHEDULER_LOCAL_SOURCE_ALIASES", localSourceAliases),
		WorkerCommand:      workerCommand,
		WorkerArgs:         workerArgs,
		JobTimeoutSeconds:  envDefaultCompat("A2O_RUNTIME_RUN_ONCE_AGENT_JOB_TIMEOUT_SECONDS", "A3_RUNTIME_RUN_ONCE_AGENT_JOB_TIMEOUT_SECONDS", envDefaultCompat("A2O_RUNTIME_SCHEDULER_AGENT_JOB_TIMEOUT_SECONDS", "A3_RUNTIME_SCHEDULER_AGENT_JOB_TIMEOUT_SECONDS", "7200")),
		BranchNamespace:    defaultBranchNamespace(config.ComposeProject),
	}, nil
}

func buildRuntimeDescribeTaskPlan(config runtimeInstanceConfig) (runtimeRunOncePlan, error) {
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
	hostRoot := envDefaultCompat("A2O_RUNTIME_RUN_ONCE_HOST_ROOT", "A3_RUNTIME_RUN_ONCE_HOST_ROOT", envDefaultCompat("A2O_RUNTIME_SCHEDULER_HOST_ROOT", "A3_RUNTIME_SCHEDULER_HOST_ROOT", filepath.Join(hostRootDir, runtimeHostAgentRelativePath)))
	_, _, _, _, repoLabels := packageRuntimeRepoArgs(hostRootDir, referencePackagePath, packageConfig)
	return runtimeRunOncePlan{
		ComposePrefix:        composeArgs(config),
		StorageDir:           envDefaultCompat("A2O_BUNDLE_STORAGE_DIR", "A3_BUNDLE_STORAGE_DIR", envDefaultValue(config.StorageDir, "/var/lib/a2o/a2o-runtime")),
		HostAgentLog:         envDefaultCompat("A2O_RUNTIME_RUN_ONCE_HOST_AGENT_LOG", "A3_RUNTIME_RUN_ONCE_HOST_AGENT_LOG", envDefaultCompat("A2O_RUNTIME_SCHEDULER_HOST_AGENT_LOG", "A3_RUNTIME_SCHEDULER_HOST_AGENT_LOG", filepath.Join(hostRoot, "agent.log"))),
		LiveLogRoot:          envDefaultCompat("A2O_AGENT_LIVE_LOG_ROOT", "A3_AGENT_LIVE_LOG_ROOT", filepath.Join(hostRoot, "live-logs")),
		AIRawLogRoot:         envDefaultCompat("A2O_AGENT_AI_RAW_LOG_ROOT", "A3_AGENT_AI_RAW_LOG_ROOT", filepath.Join(hostRoot, "ai-raw-logs")),
		ServerLog:            envDefaultCompat("A2O_RUNTIME_RUN_ONCE_SERVER_LOG", "A3_RUNTIME_RUN_ONCE_SERVER_LOG", envDefaultCompat("A2O_RUNTIME_SCHEDULER_SERVER_LOG", "A3_RUNTIME_SCHEDULER_SERVER_LOG", "/tmp/a2o-runtime-run-once-agent-server.log")),
		RuntimeLog:           envDefaultCompat("A2O_RUNTIME_RUN_ONCE_LOG", "A3_RUNTIME_RUN_ONCE_LOG", envDefaultCompat("A2O_RUNTIME_SCHEDULER_LOG", "A3_RUNTIME_SCHEDULER_LOG", "/tmp/a2o-runtime-run-once.log")),
		RuntimeExitFile:      envDefaultCompat("A2O_RUNTIME_RUN_ONCE_EXIT_FILE", "A3_RUNTIME_RUN_ONCE_EXIT_FILE", envDefaultCompat("A2O_RUNTIME_SCHEDULER_EXIT_FILE", "A3_RUNTIME_SCHEDULER_EXIT_FILE", "/tmp/a2o-runtime-run-once.exit")),
		PresetDir:            envDefaultCompat("A2O_RUNTIME_RUN_ONCE_PRESET_DIR", "A3_RUNTIME_RUN_ONCE_PRESET_DIR", envDefaultCompat("A2O_RUNTIME_SCHEDULER_PRESET_DIR", "A3_RUNTIME_SCHEDULER_PRESET_DIR", "/tmp/a3-engine/config/presets")),
		ManifestPath:         envDefaultCompat("A2O_RUNTIME_RUN_ONCE_PROJECT_CONFIG", "A3_RUNTIME_RUN_ONCE_PROJECT_CONFIG", envDefaultCompat("A2O_RUNTIME_SCHEDULER_PROJECT_CONFIG", "A3_RUNTIME_SCHEDULER_PROJECT_CONFIG", filepath.Join(referencePackagePath, "project.yaml"))),
		SoloBoardInternalURL: kanbanInternalURL(),
		KanbanProject:        envDefaultCompat("A2O_RUNTIME_RUN_ONCE_KANBAN_PROJECT", "A3_RUNTIME_RUN_ONCE_KANBAN_PROJECT", envDefaultCompat("A2O_RUNTIME_SCHEDULER_KANBAN_PROJECT", "A3_RUNTIME_SCHEDULER_KANBAN_PROJECT", packageConfig.KanbanProject)),
		KanbanStatus:         envDefaultCompat("A2O_RUNTIME_RUN_ONCE_KANBAN_STATUS", "A3_RUNTIME_RUN_ONCE_KANBAN_STATUS", envDefaultCompat("A2O_RUNTIME_SCHEDULER_KANBAN_STATUS", "A3_RUNTIME_SCHEDULER_KANBAN_STATUS", envDefaultValue(packageConfig.KanbanStatus, "To do"))),
		KanbanRepoLabels:     envDefaultListCompat("A2O_RUNTIME_RUN_ONCE_KANBAN_REPO_LABELS", "A3_RUNTIME_RUN_ONCE_KANBAN_REPO_LABELS", "A2O_RUNTIME_SCHEDULER_KANBAN_REPO_LABELS", "A3_RUNTIME_SCHEDULER_KANBAN_REPO_LABELS", repoLabels),
	}, nil
}

func kanbanInternalURL() string {
	if value := envDefaultCompat("A2O_KANBALONE_INTERNAL_URL", "A2O_SOLOBOARD_INTERNAL_URL", ""); strings.TrimSpace(value) != "" {
		return value
	}
	return envDefaultCompat("A2O_SOLOBOARD_INTERNAL_URL", "A3_SOLOBOARD_INTERNAL_URL", "http://soloboard:3000")
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

func runtimeWatchSummaryArgs(plan runtimeRunOncePlan) []string {
	args := []string{"a3", "watch-summary", "--storage-backend", "json", "--storage-dir", plan.StorageDir}
	if strings.TrimSpace(plan.KanbanProject) == "" || len(plan.KanbanRepoLabels) == 0 {
		return args
	}
	args = append(args,
		"--kanban-command", "python3",
		"--kanban-command-arg", packagedKanbanCLIPath,
		"--kanban-command-arg", "--backend",
		"--kanban-command-arg", "soloboard",
		"--kanban-command-arg", "--base-url",
		"--kanban-command-arg", plan.SoloBoardInternalURL,
		"--kanban-project", plan.KanbanProject,
		"--kanban-status", plan.KanbanStatus,
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

type runtimePhaseLogArtifact struct {
	Phase      string `json:"phase"`
	ArtifactID string `json:"artifact_id"`
	Mode       string `json:"mode"`
}

type runtimeTaskLogManifestPayload struct {
	RunRef     string                    `json:"run_ref"`
	CurrentRun string                    `json:"current_run"`
	Phase      string                    `json:"phase"`
	SourceType string                    `json:"source_type"`
	SourceRef  string                    `json:"source_ref"`
	Active     bool                      `json:"active"`
	Artifacts  []runtimePhaseLogArtifact `json:"artifacts"`
}

type runtimeTaskLogSnapshot struct {
	RunRef             string
	CurrentRunRef      string
	CurrentPhase       string
	SourceType         string
	SourceRef          string
	Active             bool
	LiveMode           string
	CompletedArtifacts []runtimePhaseLogArtifact
}

func runtimeTaskLogManifest(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, taskRef string) (runtimeTaskLogSnapshot, error) {
	taskOutput, err := runtimeDescribeSectionOutput(config, plan, runner, "task", "a3", "show-task", "--storage-backend", "json", "--storage-dir", plan.StorageDir, taskRef)
	if err != nil {
		return runtimeTaskLogSnapshot{}, err
	}
	currentRunRef := parseOutputValue(taskOutput, "current_run")
	script := strings.Join([]string{
		"records = JSON.parse(File.read(ARGV.fetch(0)))",
		"task_ref = ARGV.fetch(1)",
		"current_run = ARGV.fetch(2)",
		"run = records[current_run] unless current_run.empty?",
		"run ||= records.values.select { |record| record['task_ref'] == task_ref }.last",
		"effective_current_run = current_run",
		"if run.nil? then puts JSON.generate({'run_ref' => '', 'current_run' => effective_current_run, 'phase' => '', 'source_type' => '', 'source_ref' => '', 'active' => false, 'artifacts' => []}); exit 0 end",
		"effective_current_run = run['ref'].to_s if effective_current_run.empty? || effective_current_run != run['ref'].to_s",
		"phase_records = Array(run.dig('evidence', 'phase_records'))",
		"artifacts = phase_records.each_with_object([]) do |phase_record, result|",
		"  entries = Array(phase_record.dig('execution_record', 'diagnostics', 'agent_artifacts'))",
		"  [['ai-raw-log', 'ai-raw-log'], ['combined-log', 'combined-log']].each do |role, mode|",
		"    artifact = entries.find { |item| item['role'] == role && item['artifact_id'].to_s != '' }",
		"    next unless artifact",
		"    result << {'phase' => phase_record['phase'].to_s, 'artifact_id' => artifact['artifact_id'].to_s, 'mode' => mode}",
		"  end",
		"end",
		"payload = {'run_ref' => run['ref'].to_s, 'current_run' => effective_current_run, 'phase' => run['phase'].to_s, 'source_type' => run.dig('source_descriptor', 'source_type').to_s, 'source_ref' => run.dig('source_descriptor', 'ref').to_s, 'active' => run['terminal_outcome'].nil?, 'artifacts' => artifacts}",
		"puts JSON.generate(payload)",
	}, "; ")
	output, err := dockerComposeExecOutput(config, plan, runner, "ruby", "-rjson", "-e", script, path.Join(plan.StorageDir, "runs.json"), taskRef, currentRunRef)
	if err != nil {
		return runtimeTaskLogSnapshot{}, err
	}
	var payload runtimeTaskLogManifestPayload
	if err := json.Unmarshal(output, &payload); err != nil {
		return runtimeTaskLogSnapshot{}, err
	}
	return runtimeTaskLogSnapshot{
		RunRef:             payload.RunRef,
		CurrentRunRef:      payload.CurrentRun,
		CurrentPhase:       payload.Phase,
		SourceType:         payload.SourceType,
		SourceRef:          payload.SourceRef,
		Active:             payload.Active,
		LiveMode:           preferredLiveMode(plan, taskRef, payload.Phase),
		CompletedArtifacts: payload.Artifacts,
	}, nil
}

func printRuntimeArtifactSection(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer, phase string, artifactID string, mode string) error {
	output, err := runtimeDescribeSectionOutput(config, plan, runner, "agent_artifact", "a3", "agent-artifact-read", "--storage-dir", plan.StorageDir, artifactID)
	if err != nil {
		return err
	}
	fmt.Fprintf(stdout, "=== phase: %s (%s) artifact=%s ===\n", phase, mode, artifactID)
	if strings.TrimSpace(output) != "" {
		fmt.Fprintln(stdout, output)
	}
	return nil
}

func printFileDelta(stdout io.Writer, livePath string, offset int64) (int64, error) {
	file, err := os.Open(livePath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return offset, nil
		}
		return offset, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return offset, err
	}
	if info.Size() < offset {
		offset = 0
	}
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		return offset, err
	}
	written, err := io.Copy(stdout, file)
	if err != nil {
		return offset, err
	}
	return offset + written, nil
}

func (plan runtimeRunOncePlan) liveLogPath(taskRef string, phase string) string {
	return filepath.Join(plan.LiveLogRoot, safeRuntimeLogComponent(taskRef), safeRuntimeLogComponent(phase)+".log")
}

func (plan runtimeRunOncePlan) aiRawLogPath(taskRef string, phase string) string {
	return filepath.Join(plan.AIRawLogRoot, safeRuntimeLogComponent(taskRef), safeRuntimeLogComponent(phase)+".log")
}

func (plan runtimeRunOncePlan) preferredLiveLogPath(taskRef string, phase string) string {
	rawPath := plan.aiRawLogPath(taskRef, phase)
	if _, err := os.Stat(rawPath); err == nil {
		return rawPath
	}
	return plan.liveLogPath(taskRef, phase)
}

func preferredLiveMode(plan runtimeRunOncePlan, taskRef string, phase string) string {
	rawPath := plan.aiRawLogPath(taskRef, phase)
	if _, err := os.Stat(rawPath); err == nil {
		return "ai-raw-live"
	}
	return "live"
}

func safeRuntimeLogComponent(value string) string {
	var builder strings.Builder
	for _, ch := range value {
		switch {
		case ch >= 'A' && ch <= 'Z':
			builder.WriteRune(ch)
		case ch >= 'a' && ch <= 'z':
			builder.WriteRune(ch)
		case ch >= '0' && ch <= '9':
			builder.WriteRune(ch)
		case ch == '.', ch == '_', ch == '-', ch == ':':
			builder.WriteRune(ch)
		default:
			builder.WriteByte('-')
		}
	}
	return builder.String()
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
	taskOutput, taskErr := runtimeDescribeSectionOutput(config, plan, runner, "kanban_task", "python3", packagedKanbanCLIPath, "--backend", "soloboard", "--base-url", plan.SoloBoardInternalURL, "task-get", "--project", plan.KanbanProject, "--task", taskRef)
	if taskErr != nil {
		fmt.Fprintf(stdout, "describe_section name=kanban_task status=blocked action=check kanban service detail=%s\n", singleLine(taskErr.Error()))
	} else {
		printDescribeSection(stdout, "kanban_task", taskOutput)
	}

	commentOutput, commentErr := runtimeDescribeSectionOutput(config, plan, runner, "kanban_comments", "python3", packagedKanbanCLIPath, "--backend", "soloboard", "--base-url", plan.SoloBoardInternalURL, "task-comment-list", "--project", plan.KanbanProject, "--task", taskRef)
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
	killRuntimeProcessesByPattern(config, plan, runner, "a3 execute-until-idle")
	killRuntimeProcessesByPattern(config, plan, runner, "a3 agent-server")
	killRuntimePIDFile(config, plan, runner, plan.RuntimePIDFile)
	killRuntimePIDFile(config, plan, runner, plan.ServerPIDFile)
	return dockerComposeExec(config, plan, runner, "rm", "-f", plan.RuntimeExitFile, plan.ServerLog, plan.RuntimeLog)
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
		if _, err := runExternal(runner, "docker", "exec", containerID, "a3", "agent", "package", "verify", "--target", plan.HostAgentTarget); err != nil {
			return err
		}
		if _, err := runExternal(runner, "docker", "exec", containerID, "a3", "agent", "package", "export", "--target", plan.HostAgentTarget, "--output", "/tmp/a2o-runtime-run-once-agent"); err != nil {
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
		return "", fmt.Errorf("A2O runtime container not found; run a2o runtime up")
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
	return dockerComposeExecShell(config, plan, runner, runtimeContainerProcess{
		WorkingDir:  "/workspace",
		Args:        []string{"a3", "agent-server", "--storage-dir", plan.StorageDir, "--host", "0.0.0.0", "--port", plan.AgentInternalPort},
		StdoutPath:  plan.ServerLog,
		StderrToOut: true,
		PIDFile:     plan.ServerPIDFile,
	}.shellScript())
}

func waitForRuntimeControlPlane(plan runtimeRunOncePlan, runner commandRunner) error {
	url := fmt.Sprintf("http://127.0.0.1:%s/v1/agent/jobs/next?agent=probe", plan.AgentPort)
	var lastErr error
	for i := 0; i < 80; i++ {
		if _, err := runExternal(runner, "curl", "-fsS", url); err == nil {
			return nil
		} else {
			lastErr = err
		}
		time.Sleep(250 * time.Millisecond)
	}
	return fmt.Errorf("agent control plane did not become ready: %w", lastErr)
}

func startRuntimeExecuteUntilIdle(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer) error {
	fmt.Fprintf(stdout, "runtime_execute_until_idle_start max_steps=%s\n", plan.MaxSteps)
	return dockerComposeExecShell(config, plan, runner, runtimeContainerProcess{
		WorkingDir: "/workspace",
		Env: map[string]string{
			"A2O_BRANCH_NAMESPACE": plan.BranchNamespace,
			"A2O_ROOT_DIR":         "/workspace",
			"KANBAN_BACKEND":       "soloboard",
		},
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
		"--agent-job-timeout-seconds", plan.JobTimeoutSeconds,
		"--agent-job-poll-interval-seconds", "1.0",
		"--worker-command", plan.WorkerCommand,
	}
	for _, agentEnv := range plan.AgentEnv {
		args = append(args, "--agent-env", agentEnv)
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
		"--kanban-command-arg", "soloboard",
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
	fmt.Fprintf(stdout, "runtime_host_agent_loop attempts=%d poll_interval=%s\n", plan.AgentAttempts, plan.AgentPollInterval)
	_ = appendFile(plan.HostAgentLog, []byte(fmt.Sprintf("\n===== host agent session start %s attempts=%d poll_interval=%s =====\n", time.Now().UTC().Format(time.RFC3339), plan.AgentAttempts, plan.AgentPollInterval)))
	var agentStatus error
	for attempt := 1; attempt <= plan.AgentAttempts; attempt++ {
		fmt.Fprintf(stdout, "runtime_host_agent_attempt=%d\n", attempt)
		args := []string{"-agent", "host-local", "-control-plane-url", "http://127.0.0.1:" + plan.AgentPort}
		if envDefaultCompat("A2O_RUNTIME_RUN_ONCE_AGENT_LOCAL_MATERIALIZER_ARGS", "A3_RUNTIME_RUN_ONCE_AGENT_LOCAL_MATERIALIZER_ARGS", envDefaultCompat("A2O_RUNTIME_SCHEDULER_AGENT_LOCAL_MATERIALIZER_ARGS", "A3_RUNTIME_SCHEDULER_AGENT_LOCAL_MATERIALIZER_ARGS", "0")) == "1" {
			args = append(args, "-workspace-root", plan.WorkspaceRoot)
			for _, sourceAlias := range plan.LocalSourceAliases {
				args = append(args, "-source-alias", sourceAlias)
			}
		}
		output, err := runExternal(runner, plan.HostAgentBin, args...)
		_ = appendFile(plan.HostAgentLog, []byte(fmt.Sprintf("\n===== host agent attempt %03d %s =====\n%s", attempt, time.Now().UTC().Format(time.RFC3339), string(output))))
		if err != nil {
			agentStatus = err
		}
		if runtimeExitExists(config, plan, runner) {
			return agentStatus
		}
		if plan.AgentPollInterval > 0 {
			time.Sleep(plan.AgentPollInterval)
		}
	}
	return fmt.Errorf("runtime run-once did not finish within %d agent attempts", plan.AgentAttempts)
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

	cycle := 0
	for {
		cycle++
		fmt.Fprintf(stdout, "kanban_loop_cycle_start cycle=%d\n", cycle)
		if err := runRuntimeRunOnce(buildRunOnceArgs(*maxSteps, *agentAttempts, *agentPollInterval), runner, stdout, stderr); err != nil {
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

func buildRunOnceArgs(maxSteps string, agentAttempts string, agentPollInterval string) []string {
	args := []string{}
	if strings.TrimSpace(maxSteps) != "" {
		args = append(args, "--max-steps", strings.TrimSpace(maxSteps))
	}
	if strings.TrimSpace(agentAttempts) != "" {
		args = append(args, "--agent-attempts", strings.TrimSpace(agentAttempts))
	}
	if strings.TrimSpace(agentPollInterval) != "" {
		args = append(args, "--agent-poll-interval", strings.TrimSpace(agentPollInterval))
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
