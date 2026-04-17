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

const packagedKanbanCLIPath = "/opt/a3/share/tools/kanban/cli.py"
const packagedKanbanBootstrapPath = "/opt/a3/share/tools/kanban/bootstrap_soloboard.py"

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
	case "start":
		if err := runRuntimeStart(args[1:], runner, stdout, stderr); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	case "stop":
		if err := runRuntimeStop(args[1:], runner, stdout, stderr); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	case "status":
		if err := runRuntimeStatus(args[1:], runner, stdout, stderr); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	case "doctor":
		if err := runRuntimeDoctor(args[1:], runner, stdout, stderr); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	case "run-once":
		if err := runRuntimeRunOnce(args[1:], runner, stdout, stderr); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	case "loop":
		if err := runRuntimeLoop(args[1:], runner, stdout, stderr); err != nil {
			fmt.Fprintln(stderr, err)
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

func runRuntimeStart(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime start", flag.ContinueOnError)
	flags.SetOutput(stderr)
	interval := flags.String("interval", "60s", "duration between scheduler cycles")
	maxSteps := flags.String("max-steps", "", "maximum runtime steps for each cycle")
	agentAttempts := flags.String("agent-attempts", "", "maximum host agent attempts for each cycle")
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

	config, _, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	if _, err := buildRuntimeRunOncePlan(effectiveConfig, *maxSteps, *agentAttempts); err != nil {
		return err
	}
	paths := schedulerPaths(effectiveConfig)
	if err := os.MkdirAll(paths.Dir, 0o755); err != nil {
		return fmt.Errorf("create scheduler dir: %w", err)
	}
	if pid, ok, err := readRunningScheduler(paths.PIDFile, runner); err != nil {
		return err
	} else if ok {
		return fmt.Errorf("runtime scheduler already running pid=%d", pid)
	}
	executable, err := os.Executable()
	if err != nil {
		return fmt.Errorf("resolve executable: %w", err)
	}
	loopArgs := []string{"runtime", "loop", "--interval", *interval}
	loopArgs = append(loopArgs, buildRunOnceArgs(*maxSteps, *agentAttempts)...)
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
	fmt.Fprintf(stdout, "runtime_scheduler_started pid_file=%s log=%s\n", paths.PIDFile, paths.LogFile)
	return nil
}

func runRuntimeStop(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime stop", flag.ContinueOnError)
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
	paths := schedulerPaths(applyAgentInstallOverrides(*config, "", "", ""))
	pid, err := readSchedulerPID(paths.PIDFile)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			fmt.Fprintf(stdout, "runtime_scheduler_status=stopped pid_file=%s log=%s\n", paths.PIDFile, paths.LogFile)
			return nil
		}
		return err
	}
	running := schedulerProcessRunning(pid, paths.CommandFile, runner)
	plan, planErr := buildRuntimeRunOncePlan(pathsConfig(config), "", "")
	if running {
		if err := runner.TerminateProcessGroup(pid); err != nil {
			return err
		}
	}
	if planErr == nil {
		_ = cleanupRuntimeProcesses(pathsConfig(config), plan, runner)
	}
	if err := os.Remove(paths.PIDFile); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove scheduler pid file: %w", err)
	}
	if err := os.Remove(paths.CommandFile); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove scheduler command file: %w", err)
	}
	fmt.Fprintf(stdout, "runtime_scheduler_stopped pid=%d pid_file=%s log=%s\n", pid, paths.PIDFile, paths.LogFile)
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

	config, _, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	paths := schedulerPaths(applyAgentInstallOverrides(*config, "", "", ""))
	pid, err := readSchedulerPID(paths.PIDFile)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			fmt.Fprintf(stdout, "runtime_scheduler_status=stopped pid_file=%s log=%s\n", paths.PIDFile, paths.LogFile)
			return nil
		}
		return err
	}
	if schedulerProcessRunning(pid, paths.CommandFile, runner) {
		fmt.Fprintf(stdout, "runtime_scheduler_status=running pid=%d pid_file=%s log=%s\n", pid, paths.PIDFile, paths.LogFile)
		return nil
	}
	fmt.Fprintf(stdout, "runtime_scheduler_status=stale pid=%d pid_file=%s log=%s\n", pid, paths.PIDFile, paths.LogFile)
	return nil
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
	composePrefix := composeArgs(*config)
	return withComposeEnv(*config, func() error {
		if *build {
			if _, err := runExternal(runner, "docker", append(composePrefix, "build", config.RuntimeService)...); err != nil {
				return err
			}
		}
		if _, err := runExternal(runner, "docker", append(composePrefix, "up", "-d", config.RuntimeService, "soloboard")...); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "runtime_up compose_project=%s package=%s\n", config.ComposeProject, config.PackagePath)
		return nil
	})
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
	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", configPath)
	fmt.Fprintf(stdout, "package=%s\n", config.PackagePath)
	fmt.Fprintf(stdout, "compose_project=%s\n", config.ComposeProject)
	output, err := runExternal(runner, "docker", append(composeArgs(*config), "ps")...)
	if err != nil {
		return err
	}
	fmt.Fprint(stdout, string(output))
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
	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", configPath)
	fmt.Fprintln(stdout, "kanban_up=a2o kanban up")
	fmt.Fprintln(stdout, "kanban_doctor=a2o kanban doctor")
	fmt.Fprintf(stdout, "kanban_url=%s\n", kanbanPublicURL(*config))
	fmt.Fprintf(stdout, "internal_runtime_up=docker compose -p %s -f %s up -d %s soloboard\n", config.ComposeProject, config.ComposeFile, config.RuntimeService)
	fmt.Fprintf(stdout, "agent_install=a2o agent install --target auto --output ./.work/a2o-agent/bin/a2o-agent\n")
	return nil
}

func runRuntimeRunOnce(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime run-once", flag.ContinueOnError)
	flags.SetOutput(stderr)
	maxSteps := flags.String("max-steps", "", "maximum runtime steps for this cycle")
	agentAttempts := flags.String("agent-attempts", "", "maximum host agent attempts for this cycle")
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

	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", configPath)
	return withEnv(runtimeRunOnceEnv(effectiveConfig, *maxSteps, *agentAttempts), func() error {
		return runGenericRuntimeRunOnce(effectiveConfig, *maxSteps, *agentAttempts, runner, stdout)
	})
}

type runtimeRunOncePlan struct {
	ComposePrefix        []string
	MaxSteps             string
	AgentAttempts        int
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

func runGenericRuntimeRunOnce(config runtimeInstanceConfig, maxSteps string, agentAttempts string, runner commandRunner, stdout io.Writer) error {
	plan, err := buildRuntimeRunOncePlan(config, maxSteps, agentAttempts)
	if err != nil {
		return err
	}
	return withComposeEnv(config, func() error {
		fmt.Fprintf(stdout, "kanban_run_once=generic\n")
		if _, err := runExternal(runner, "docker", append(plan.ComposePrefix, "up", "-d", config.RuntimeService, "soloboard")...); err != nil {
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

func buildRuntimeRunOncePlan(config runtimeInstanceConfig, maxSteps string, agentAttempts string) (runtimeRunOncePlan, error) {
	hostRootDir := envDefault("A3_RUNTIME_RUN_ONCE_HOST_ROOT_DIR", envDefault("A3_RUNTIME_SCHEDULER_HOST_ROOT_DIR", config.WorkspaceRoot))
	if strings.TrimSpace(hostRootDir) == "" {
		hostRootDir = "."
	}
	referencePackagePath := envDefault("A3_RUNTIME_RUN_ONCE_REFERENCE_PACKAGE", envDefault("A3_RUNTIME_SCHEDULER_REFERENCE_PACKAGE", config.PackagePath))
	if strings.TrimSpace(referencePackagePath) == "" {
		return runtimeRunOncePlan{}, errors.New("runtime package path is empty; run `a2o project bootstrap --package ./a2o-project` first")
	}
	packageConfig, err := loadProjectPackageConfig(referencePackagePath)
	if err != nil {
		return runtimeRunOncePlan{}, err
	}
	hostRoot := envDefault("A3_RUNTIME_RUN_ONCE_HOST_ROOT", envDefault("A3_RUNTIME_SCHEDULER_HOST_ROOT", filepath.Join(hostRootDir, ".work", "a3", "runtime-host-agent")))
	defaultWorkspaceRoot := filepath.Join(hostRoot, "workspaces")
	if strings.TrimSpace(packageConfig.AgentWorkspaceRoot) != "" {
		defaultWorkspaceRoot = resolvePackagePath(hostRootDir, packageConfig.AgentWorkspaceRoot)
	}
	workspaceRoot := envDefault("A3_RUNTIME_RUN_ONCE_AGENT_WORKSPACE_ROOT", envDefault("A3_RUNTIME_SCHEDULER_AGENT_WORKSPACE_ROOT", defaultWorkspaceRoot))
	hostAgentBin := envDefault("A3_HOST_AGENT_BIN", resolveDefaultHostAgentBin(config, hostRootDir))
	defaultAgentAttempts := envDefaultValue(packageConfig.AgentAttempts, "220")
	agentAttemptCount, err := parsePositiveInt(envDefaultValue(agentAttempts, envDefault("A3_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS", envDefault("A3_RUNTIME_SCHEDULER_AGENT_ATTEMPTS", defaultAgentAttempts))), "agent attempts")
	if err != nil {
		return runtimeRunOncePlan{}, err
	}
	target := envDefault("A3_RUNTIME_RUN_ONCE_AGENT_TARGET", envDefault("A3_RUNTIME_SCHEDULER_AGENT_TARGET", ""))
	if strings.TrimSpace(target) == "" {
		detected, err := detectHostTarget()
		if err != nil {
			return runtimeRunOncePlan{}, err
		}
		target = detected
	}
	workerCommand := envDefault("A3_RUNTIME_RUN_ONCE_WORKER_COMMAND", envDefault("A3_RUNTIME_SCHEDULER_WORKER_COMMAND", hostAgentBin))
	workerArgs := []string{"worker", "stdin-bundle"}
	if override := envDefault("A3_RUNTIME_RUN_ONCE_WORKER_ARGS", envDefault("A3_RUNTIME_SCHEDULER_WORKER_ARGS", "")); strings.TrimSpace(override) != "" {
		workerArgs = strings.Fields(override)
	}
	if workerScript := envDefault("A3_RUNTIME_RUN_ONCE_WORKER", envDefault("A3_RUNTIME_SCHEDULER_WORKER", "")); strings.TrimSpace(workerScript) != "" {
		effectiveWorker := workerScript
		if strings.HasPrefix(effectiveWorker, "/workspace/") {
			effectiveWorker = filepath.Join(hostRootDir, strings.TrimPrefix(effectiveWorker, "/workspace/"))
		}
		workerCommand = "ruby"
		workerArgs = []string{effectiveWorker}
	}
	agentSourcePaths, agentSourceAliases, localSourceAliases, repoSources, repoLabels := packageRuntimeRepoArgs(hostRootDir, referencePackagePath, packageConfig)
	requiredBins := packageConfig.AgentRequiredBins
	if len(requiredBins) == 0 {
		requiredBins = []string{"git", "node"}
	}
	defaultMaxSteps := envDefaultValue(packageConfig.MaxSteps, "16")
	defaultLiveRef := envDefaultValue(packageConfig.LiveRef, "refs/heads/feature/prototype")
	defaultKanbanProject := packageConfig.KanbanProject
	defaultKanbanStatus := envDefaultValue(packageConfig.KanbanStatus, "To do")
	launcherConfigPath := envDefault("A3_WORKER_LAUNCHER_CONFIG_PATH", filepath.Join(hostRootDir, "launcher.json"))
	if len(packageConfig.Executor) == 0 && strings.TrimSpace(envDefault("A3_WORKER_LAUNCHER_CONFIG_PATH", "")) == "" {
		return runtimeRunOncePlan{}, fmt.Errorf("project.yaml runtime.executor is required for packaged a2o-agent worker execution")
	}
	return runtimeRunOncePlan{
		ComposePrefix:        composeArgs(config),
		MaxSteps:             envDefaultValue(maxSteps, envDefault("A3_RUNTIME_RUN_ONCE_MAX_STEPS", envDefault("A3_RUNTIME_SCHEDULER_MAX_STEPS", defaultMaxSteps))),
		AgentAttempts:        agentAttemptCount,
		AgentPort:            envDefault("A3_BUNDLE_AGENT_PORT", envDefaultValue(config.AgentPort, "7393")),
		AgentInternalPort:    envDefault("A3_RUNTIME_RUN_ONCE_AGENT_INTERNAL_PORT", envDefault("A3_RUNTIME_SCHEDULER_AGENT_INTERNAL_PORT", "7393")),
		StorageDir:           envDefault("A3_BUNDLE_STORAGE_DIR", envDefaultValue(config.StorageDir, "/var/lib/a3/a2o-runtime")),
		HostRootDir:          hostRootDir,
		HostRoot:             hostRoot,
		WorkspaceRoot:        workspaceRoot,
		HostAgentBin:         hostAgentBin,
		HostAgentSource:      envDefault("A3_RUNTIME_RUN_ONCE_AGENT_SOURCE", envDefault("A3_RUNTIME_SCHEDULER_AGENT_SOURCE", "runtime-image")),
		HostAgentTarget:      target,
		HostAgentLog:         envDefault("A3_RUNTIME_RUN_ONCE_HOST_AGENT_LOG", envDefault("A3_RUNTIME_SCHEDULER_HOST_AGENT_LOG", filepath.Join(hostRoot, "agent.log"))),
		LauncherConfigPath:   launcherConfigPath,
		LauncherConfig:       packageConfig.Executor,
		ServerLog:            envDefault("A3_RUNTIME_RUN_ONCE_SERVER_LOG", envDefault("A3_RUNTIME_SCHEDULER_SERVER_LOG", "/tmp/a3-runtime-run-once-agent-server.log")),
		RuntimeLog:           envDefault("A3_RUNTIME_RUN_ONCE_LOG", envDefault("A3_RUNTIME_SCHEDULER_LOG", "/tmp/a3-runtime-run-once.log")),
		RuntimeExitFile:      envDefault("A3_RUNTIME_RUN_ONCE_EXIT_FILE", envDefault("A3_RUNTIME_SCHEDULER_EXIT_FILE", "/tmp/a3-runtime-run-once.exit")),
		RuntimePIDFile:       envDefault("A3_RUNTIME_RUN_ONCE_PID_FILE", envDefault("A3_RUNTIME_SCHEDULER_PID_FILE", "/tmp/a3-runtime-run-once.pid")),
		ServerPIDFile:        envDefault("A3_RUNTIME_RUN_ONCE_SERVER_PID_FILE", envDefault("A3_RUNTIME_SCHEDULER_SERVER_PID_FILE", "/tmp/a3-runtime-run-once-agent-server.pid")),
		PresetDir:            envDefault("A3_RUNTIME_RUN_ONCE_PRESET_DIR", envDefault("A3_RUNTIME_SCHEDULER_PRESET_DIR", "/tmp/a3-engine/config/presets")),
		ManifestPath:         envDefault("A3_RUNTIME_RUN_ONCE_PROJECT_CONFIG", envDefault("A3_RUNTIME_SCHEDULER_PROJECT_CONFIG", filepath.Join(referencePackagePath, "project.yaml"))),
		SoloBoardInternalURL: envDefault("A3_SOLOBOARD_INTERNAL_URL", "http://soloboard:3000"),
		LiveRef:              envDefault("A3_RUNTIME_RUN_ONCE_LIVE_REF", envDefault("A3_RUNTIME_SCHEDULER_LIVE_REF", defaultLiveRef)),
		AgentEnv: []string{
			"A3_ROOT_DIR=" + hostRootDir,
			"A2O_ROOT_DIR=" + hostRootDir,
			"A3_WORKER_LAUNCHER_CONFIG_PATH=" + launcherConfigPath,
			"A3_MAVEN_WORKSPACE_BOOTSTRAP_MODE=" + envDefault("A3_RUNTIME_RUN_ONCE_MAVEN_WORKSPACE_BOOTSTRAP_MODE", envDefault("A3_RUNTIME_SCHEDULER_MAVEN_WORKSPACE_BOOTSTRAP_MODE", "empty")),
		},
		AgentSourcePaths:   envDefaultList("A3_RUNTIME_RUN_ONCE_AGENT_SOURCE_PATHS", "A3_RUNTIME_SCHEDULER_AGENT_SOURCE_PATHS", agentSourcePaths),
		AgentRequiredBins:  envDefaultList("A3_RUNTIME_RUN_ONCE_AGENT_REQUIRED_BINS", "A3_RUNTIME_SCHEDULER_AGENT_REQUIRED_BINS", requiredBins),
		AgentSourceAliases: envDefaultList("A3_RUNTIME_RUN_ONCE_AGENT_SOURCE_ALIASES", "A3_RUNTIME_SCHEDULER_AGENT_SOURCE_ALIASES", agentSourceAliases),
		KanbanProject:      envDefault("A3_RUNTIME_RUN_ONCE_KANBAN_PROJECT", envDefault("A3_RUNTIME_SCHEDULER_KANBAN_PROJECT", defaultKanbanProject)),
		KanbanStatus:       envDefault("A3_RUNTIME_RUN_ONCE_KANBAN_STATUS", envDefault("A3_RUNTIME_SCHEDULER_KANBAN_STATUS", defaultKanbanStatus)),
		KanbanRepoLabels:   envDefaultList("A3_RUNTIME_RUN_ONCE_KANBAN_REPO_LABELS", "A3_RUNTIME_SCHEDULER_KANBAN_REPO_LABELS", repoLabels),
		RepoSources:        envDefaultList("A3_RUNTIME_RUN_ONCE_REPO_SOURCES", "A3_RUNTIME_SCHEDULER_REPO_SOURCES", repoSources),
		LocalSourceAliases: envDefaultList("A3_RUNTIME_RUN_ONCE_LOCAL_SOURCE_ALIASES", "A3_RUNTIME_SCHEDULER_LOCAL_SOURCE_ALIASES", localSourceAliases),
		WorkerCommand:      workerCommand,
		WorkerArgs:         workerArgs,
		JobTimeoutSeconds:  envDefault("A3_RUNTIME_RUN_ONCE_AGENT_JOB_TIMEOUT_SECONDS", envDefault("A3_RUNTIME_SCHEDULER_AGENT_JOB_TIMEOUT_SECONDS", "7200")),
		BranchNamespace:    config.ComposeProject,
	}, nil
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

func archiveRuntimeStateIfRequested(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer) error {
	if envDefault("A3_RUNTIME_RUN_ONCE_ARCHIVE_STATE", envDefault("A3_RUNTIME_SCHEDULER_ARCHIVE_STATE", "0")) != "1" {
		return nil
	}
	fmt.Fprintf(stdout, "runtime_archive_state storage=%s\n", plan.StorageDir)
	if err := dockerComposeExec(config, plan, runner, "mkdir", "-p", "/var/lib/a3/archive"); err != nil {
		return err
	}
	if _, err := dockerComposeExecOutput(config, plan, runner, "test", "-e", plan.StorageDir); err == nil {
		stampBytes, err := dockerComposeExecOutput(config, plan, runner, "date", "-u", "+%Y%m%dT%H%M%SZ")
		if err != nil {
			return err
		}
		stamp := strings.TrimSpace(string(stampBytes))
		archivePath := path.Join("/var/lib/a3/archive", path.Base(plan.StorageDir)+"-"+stamp)
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
		if _, err := runExternal(runner, "docker", "exec", containerID, "a3", "agent", "package", "export", "--target", plan.HostAgentTarget, "--output", "/tmp/a3-runtime-run-once-agent"); err != nil {
			return err
		}
		if _, err := runExternal(runner, "docker", "cp", containerID+":/tmp/a3-runtime-run-once-agent", plan.HostAgentBin); err != nil {
			return err
		}
		return os.Chmod(plan.HostAgentBin, 0o755)
	case "source":
		fmt.Fprintf(stdout, "runtime_agent_build output=%s\n", plan.HostAgentBin)
		buildDir := filepath.Join(plan.HostRootDir, "a3-engine", "agent-go")
		_, err := runExternal(runner, "bash", "-lc", "cd "+shellQuote(buildDir)+" && go build -trimpath -o "+shellQuote(plan.HostAgentBin)+" ./cmd/a3-agent")
		return err
	default:
		return fmt.Errorf("unsupported A3_RUNTIME_RUN_ONCE_AGENT_SOURCE: %s", plan.HostAgentSource)
	}
}

func runtimeContainerID(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner) (string, error) {
	output, err := runExternal(runner, "docker", append(plan.ComposePrefix, "ps", "-q", config.RuntimeService)...)
	if err != nil {
		return "", err
	}
	containerID := strings.TrimSpace(string(output))
	if containerID == "" {
		return "", fmt.Errorf("runtime container not found for service %q", config.RuntimeService)
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
			"A3_BRANCH_NAMESPACE": plan.BranchNamespace,
			"A3_ROOT_DIR":         "/workspace",
			"A2O_ROOT_DIR":        "/workspace",
			"KANBAN_BACKEND":      "soloboard",
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
		"--kanban-follow-up-label", "a3:follow-up-child",
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
	fmt.Fprintf(stdout, "runtime_host_agent_loop attempts=%d\n", plan.AgentAttempts)
	_ = os.Remove(plan.HostAgentLog)
	var agentStatus error
	for attempt := 1; attempt <= plan.AgentAttempts; attempt++ {
		fmt.Fprintf(stdout, "runtime_host_agent_attempt=%d\n", attempt)
		args := []string{"-agent", "host-local", "-control-plane-url", "http://127.0.0.1:" + plan.AgentPort}
		if envDefault("A3_RUNTIME_RUN_ONCE_AGENT_LOCAL_MATERIALIZER_ARGS", envDefault("A3_RUNTIME_SCHEDULER_AGENT_LOCAL_MATERIALIZER_ARGS", "0")) == "1" {
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
		time.Sleep(time.Second)
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

	cycle := 0
	for {
		cycle++
		fmt.Fprintf(stdout, "kanban_loop_cycle_start cycle=%d\n", cycle)
		if err := runRuntimeRunOnce(buildRunOnceArgs(*maxSteps, *agentAttempts), runner, stdout, stderr); err != nil {
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

func buildRunOnceArgs(maxSteps string, agentAttempts string) []string {
	args := []string{}
	if strings.TrimSpace(maxSteps) != "" {
		args = append(args, "--max-steps", strings.TrimSpace(maxSteps))
	}
	if strings.TrimSpace(agentAttempts) != "" {
		args = append(args, "--agent-attempts", strings.TrimSpace(agentAttempts))
	}
	return args
}
