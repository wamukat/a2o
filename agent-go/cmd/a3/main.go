package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const version = "dev"
const instanceConfigRelativePath = ".a3/runtime-instance.json"

type runtimeInstanceConfig struct {
	SchemaVersion  int    `json:"schema_version"`
	PackagePath    string `json:"package_path"`
	WorkspaceRoot  string `json:"workspace_root"`
	ComposeFile    string `json:"compose_file"`
	ComposeProject string `json:"compose_project"`
	RuntimeService string `json:"runtime_service"`
	SoloBoardPort  string `json:"soloboard_port"`
	AgentPort      string `json:"agent_port"`
	StorageDir     string `json:"storage_dir"`
}

type commandRunner interface {
	Run(name string, args ...string) ([]byte, error)
}

type execRunner struct{}

func (execRunner) Run(name string, args ...string) ([]byte, error) {
	cmd := exec.Command(name, args...)
	return cmd.CombinedOutput()
}

func main() {
	os.Exit(run(os.Args[1:], execRunner{}, os.Stdout, os.Stderr))
}

func run(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		printUsage(stderr)
		return 2
	}

	switch args[0] {
	case "version":
		fmt.Fprintf(stdout, "a3 version=%s\n", version)
		return 0
	case "project":
		return runProject(args[1:], stdout, stderr)
	case "runtime":
		return runRuntime(args[1:], runner, stdout, stderr)
	case "kanban":
		return runKanban(args[1:], runner, stdout, stderr)
	case "agent":
		return runAgent(args[1:], runner, stdout, stderr)
	case "help", "-h", "--help":
		printUsage(stdout)
		return 0
	default:
		fmt.Fprintf(stderr, "unknown command: %s\n", args[0])
		printUsage(stderr)
		return 2
	}
}

func printUsage(w io.Writer) {
	fmt.Fprintln(w, "usage:")
	fmt.Fprintln(w, "  a2o version")
	fmt.Fprintln(w, "  a2o project bootstrap --package DIR")
	fmt.Fprintln(w, "  a2o kanban up [--build]")
	fmt.Fprintln(w, "  a2o kanban doctor")
	fmt.Fprintln(w, "  a2o kanban url")
	fmt.Fprintln(w, "  a2o runtime run-once [--max-steps N] [--agent-attempts N]")
	fmt.Fprintln(w, "  a2o runtime loop [--interval DURATION] [--max-cycles N] [--max-steps N] [--agent-attempts N]")
	fmt.Fprintln(w, "  a2o agent target")
	fmt.Fprintln(w, "  a2o agent install --target auto --output PATH [--build]")
}

func runKanban(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "missing kanban subcommand")
		printUsage(stderr)
		return 2
	}

	switch args[0] {
	case "up":
		if err := runKanbanUp(args[1:], runner, stdout, stderr); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	case "doctor":
		if err := runKanbanDoctor(args[1:], runner, stdout, stderr); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	case "url":
		if err := runKanbanURL(args[1:], stdout, stderr); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	default:
		fmt.Fprintf(stderr, "unknown kanban subcommand: %s\n", args[0])
		printUsage(stderr)
		return 2
	}
}

func runProject(args []string, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "missing project subcommand")
		printUsage(stderr)
		return 2
	}
	switch args[0] {
	case "bootstrap":
		if err := runProjectBootstrap(args[1:], stdout, stderr); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	default:
		fmt.Fprintf(stderr, "unknown project subcommand: %s\n", args[0])
		printUsage(stderr)
		return 2
	}
}

func runProjectBootstrap(args []string, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a3 project bootstrap", flag.ContinueOnError)
	flags.SetOutput(stderr)

	packagePath := flags.String("package", "", "project package directory")
	workspaceRoot := flags.String("workspace", ".", "workspace root where .a3/runtime-instance.json is written")
	composeProject := flags.String("compose-project", "", "docker compose project name for this runtime instance")
	composeFile := flags.String("compose-file", "", "A3 distribution compose file")
	runtimeService := flags.String("runtime-service", "a3-runtime", "docker compose runtime service name")
	soloBoardPort := flags.String("soloboard-port", "3470", "host kanban service port")
	agentPort := flags.String("agent-port", "7393", "host A3 agent control-plane port")
	storageDir := flags.String("storage-dir", "/var/lib/a3/portal-runtime", "runtime storage dir inside the A3 runtime container")

	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	if strings.TrimSpace(*packagePath) == "" {
		return errors.New("--package is required")
	}

	absWorkspaceRoot, err := filepath.Abs(*workspaceRoot)
	if err != nil {
		return fmt.Errorf("resolve workspace root: %w", err)
	}
	absPackagePath, err := filepath.Abs(*packagePath)
	if err != nil {
		return fmt.Errorf("resolve package path: %w", err)
	}
	info, err := os.Stat(absPackagePath)
	if err != nil {
		return fmt.Errorf("project package not found: %w", err)
	}
	if !info.IsDir() {
		return fmt.Errorf("project package must be a directory: %s", absPackagePath)
	}

	projectName := strings.TrimSpace(*composeProject)
	if projectName == "" {
		projectName = defaultComposeProjectName(absPackagePath)
	}
	resolvedComposeFile := strings.TrimSpace(*composeFile)
	if resolvedComposeFile == "" {
		resolvedComposeFile = defaultComposeFile()
	}
	if absComposeFile, err := filepath.Abs(resolvedComposeFile); err == nil {
		resolvedComposeFile = absComposeFile
	}

	config := runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    absPackagePath,
		WorkspaceRoot:  absWorkspaceRoot,
		ComposeFile:    resolvedComposeFile,
		ComposeProject: projectName,
		RuntimeService: strings.TrimSpace(*runtimeService),
		SoloBoardPort:  strings.TrimSpace(*soloBoardPort),
		AgentPort:      strings.TrimSpace(*agentPort),
		StorageDir:     strings.TrimSpace(*storageDir),
	}
	if err := writeInstanceConfig(absWorkspaceRoot, config); err != nil {
		return err
	}

	fmt.Fprintf(stdout, "project_bootstrapped package=%s instance_config=%s\n", config.PackagePath, filepath.Join(absWorkspaceRoot, instanceConfigRelativePath))
	return nil
}

func runKanbanUp(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a3 kanban up", flag.ContinueOnError)
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
		fmt.Fprintf(stdout, "kanban_up compose_project=%s url=%s\n", config.ComposeProject, kanbanPublicURL(*config))
		return nil
	})
}

func runKanbanDoctor(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a3 kanban doctor", flag.ContinueOnError)
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
	fmt.Fprintf(stdout, "kanban_url=%s\n", kanbanPublicURL(*config))
	fmt.Fprintf(stdout, "compose_project=%s\n", config.ComposeProject)
	output, err := runExternal(runner, "docker", append(composeArgs(*config), "ps", "soloboard")...)
	if err != nil {
		return err
	}
	fmt.Fprint(stdout, string(output))
	return nil
}

func runKanbanURL(args []string, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a3 kanban url", flag.ContinueOnError)
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
	fmt.Fprintln(stdout, kanbanPublicURL(*config))
	return nil
}

func kanbanPublicURL(config runtimeInstanceConfig) string {
	return "http://localhost:" + envDefaultValue(config.SoloBoardPort, "3470") + "/"
}

func runRuntime(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "missing runtime subcommand")
		printUsage(stderr)
		return 2
	}

	switch args[0] {
	case "down":
		if err := runRuntimeDown(args[1:], runner, stdout, stderr); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	case "command-plan":
		if err := runRuntimeCommandPlan(args[1:], stdout, stderr); err != nil {
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

func runRuntimeUp(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a3 runtime up", flag.ContinueOnError)
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
	flags := flag.NewFlagSet("a3 runtime doctor", flag.ContinueOnError)
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
	flags := flag.NewFlagSet("a3 runtime down", flag.ContinueOnError)
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
	flags := flag.NewFlagSet("a3 runtime command-plan", flag.ContinueOnError)
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
	fmt.Fprintf(stdout, "runtime_run_once=a2o runtime run-once\n")
	fmt.Fprintf(stdout, "runtime_loop=a2o runtime loop\n")
	return nil
}

func runRuntimeRunOnce(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a3 runtime run-once", flag.ContinueOnError)
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
	StorageDir           string
	HostRootDir          string
	HostRoot             string
	WorkspaceRoot        string
	HostAgentBin         string
	HostAgentSource      string
	HostAgentTarget      string
	HostAgentLog         string
	ServerLog            string
	RuntimeLog           string
	RuntimeExitFile      string
	RuntimePIDFile       string
	ServerPIDFile        string
	ManifestPath         string
	SoloBoardInternalURL string
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
		fmt.Fprintf(stdout, "runtime_run_once=generic\n")
		if _, err := runExternal(runner, "docker", append(plan.ComposePrefix, "up", "-d", config.RuntimeService, "soloboard")...); err != nil {
			return err
		}
		if err := archiveRuntimeStateIfRequested(config, plan, runner, stdout); err != nil {
			return err
		}
		if err := cleanupRuntimeProcesses(config, plan, runner); err != nil {
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
		fmt.Fprintf(stdout, "runtime_run_once_finished exit=%s\n", runtimeExit)
		if runtimeExit != "0" {
			_ = printRuntimeDiagnostics(config, plan, runner, stdout)
			return fmt.Errorf("runtime run-once failed with exit=%s", runtimeExit)
		}
		return printRuntimeSuccessTail(config, plan, runner, stdout)
	})
}

func buildRuntimeRunOncePlan(config runtimeInstanceConfig, maxSteps string, agentAttempts string) (runtimeRunOncePlan, error) {
	hostRootDir := envDefault("A3_RUNTIME_RUN_ONCE_HOST_ROOT_DIR", envDefault("A3_RUNTIME_SCHEDULER_HOST_ROOT_DIR", config.WorkspaceRoot))
	if strings.TrimSpace(hostRootDir) == "" {
		hostRootDir = "."
	}
	hostRoot := envDefault("A3_RUNTIME_RUN_ONCE_HOST_ROOT", envDefault("A3_RUNTIME_SCHEDULER_HOST_ROOT", filepath.Join(hostRootDir, ".work", "a3", "runtime-host-agent")))
	workspaceRoot := envDefault("A3_RUNTIME_RUN_ONCE_AGENT_WORKSPACE_ROOT", envDefault("A3_RUNTIME_SCHEDULER_AGENT_WORKSPACE_ROOT", filepath.Join(hostRoot, "workspaces")))
	hostAgentBin := envDefault("A3_HOST_AGENT_BIN", resolveDefaultHostAgentBin(config, hostRootDir))
	agentAttemptCount, err := parsePositiveInt(envDefaultValue(agentAttempts, envDefault("A3_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS", envDefault("A3_RUNTIME_SCHEDULER_AGENT_ATTEMPTS", "220"))), "agent attempts")
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
	workerCommand := envDefault("A3_RUNTIME_RUN_ONCE_WORKER_COMMAND", envDefault("A3_RUNTIME_SCHEDULER_WORKER_COMMAND", "ruby"))
	workerArgs := []string{"-I", filepath.Join(hostRootDir, "a3-engine", "lib"), filepath.Join(hostRootDir, "a3-engine", "bin", "a3"), "worker:stdin-bundle"}
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
	return runtimeRunOncePlan{
		ComposePrefix:        composeArgs(config),
		MaxSteps:             envDefaultValue(maxSteps, envDefault("A3_RUNTIME_RUN_ONCE_MAX_STEPS", envDefault("A3_RUNTIME_SCHEDULER_MAX_STEPS", "16"))),
		AgentAttempts:        agentAttemptCount,
		AgentPort:            envDefault("A3_BUNDLE_AGENT_PORT", envDefaultValue(config.AgentPort, "7393")),
		StorageDir:           envDefault("PORTAL_A3_BUNDLE_STORAGE_DIR", envDefaultValue(config.StorageDir, "/var/lib/a3/portal-runtime")),
		HostRootDir:          hostRootDir,
		HostRoot:             hostRoot,
		WorkspaceRoot:        workspaceRoot,
		HostAgentBin:         hostAgentBin,
		HostAgentSource:      envDefault("A3_RUNTIME_RUN_ONCE_AGENT_SOURCE", envDefault("A3_RUNTIME_SCHEDULER_AGENT_SOURCE", "runtime-image")),
		HostAgentTarget:      target,
		HostAgentLog:         envDefault("A3_RUNTIME_RUN_ONCE_HOST_AGENT_LOG", envDefault("A3_RUNTIME_SCHEDULER_HOST_AGENT_LOG", filepath.Join(hostRoot, "agent.log"))),
		ServerLog:            envDefault("A3_RUNTIME_RUN_ONCE_SERVER_LOG", envDefault("A3_RUNTIME_SCHEDULER_SERVER_LOG", "/tmp/a3-runtime-run-once-agent-server.log")),
		RuntimeLog:           envDefault("A3_RUNTIME_RUN_ONCE_LOG", envDefault("A3_RUNTIME_SCHEDULER_LOG", "/tmp/a3-runtime-run-once.log")),
		RuntimeExitFile:      envDefault("A3_RUNTIME_RUN_ONCE_EXIT_FILE", envDefault("A3_RUNTIME_SCHEDULER_EXIT_FILE", "/tmp/a3-runtime-run-once.exit")),
		RuntimePIDFile:       envDefault("A3_RUNTIME_RUN_ONCE_PID_FILE", envDefault("A3_RUNTIME_SCHEDULER_PID_FILE", "/tmp/a3-runtime-run-once.pid")),
		ServerPIDFile:        envDefault("A3_RUNTIME_RUN_ONCE_SERVER_PID_FILE", envDefault("A3_RUNTIME_SCHEDULER_SERVER_PID_FILE", "/tmp/a3-runtime-run-once-agent-server.pid")),
		ManifestPath:         envDefault("A3_RUNTIME_RUN_ONCE_MANIFEST", envDefault("A3_RUNTIME_SCHEDULER_MANIFEST", "scripts/a3-projects/portal/inject/config/portal/a3-runtime-manifest.yml")),
		SoloBoardInternalURL: envDefault("A3_PORTAL_BUNDLE_SOLOBOARD_INTERNAL_URL", "http://soloboard:3000"),
		WorkerCommand:        workerCommand,
		WorkerArgs:           workerArgs,
		JobTimeoutSeconds:    envDefault("A3_RUNTIME_RUN_ONCE_AGENT_JOB_TIMEOUT_SECONDS", envDefault("A3_RUNTIME_SCHEDULER_AGENT_JOB_TIMEOUT_SECONDS", "7200")),
		BranchNamespace:      config.ComposeProject,
	}, nil
}

func archiveRuntimeStateIfRequested(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer) error {
	if envDefault("A3_RUNTIME_RUN_ONCE_ARCHIVE_STATE", envDefault("A3_RUNTIME_SCHEDULER_ARCHIVE_STATE", "0")) != "1" {
		return nil
	}
	fmt.Fprintf(stdout, "runtime_archive_state storage=%s\n", plan.StorageDir)
	script := fmt.Sprintf("set -euo pipefail\nstorage=%s\narchive_root=/var/lib/a3/archive\nstamp=\"$(date -u +%%Y%%m%%dT%%H%%M%%SZ)\"\nmkdir -p \"$archive_root\"\nif [ -e \"$storage\" ]; then mv \"$storage\" \"$archive_root/$(basename \"$storage\")-$stamp\"; fi\nmkdir -p \"$storage\"\n", shellQuote(plan.StorageDir))
	_, err := runExternal(runner, "docker", append(plan.ComposePrefix, "exec", "-T", config.RuntimeService, "bash", "-lc", script)...)
	return err
}

func cleanupRuntimeProcesses(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner) error {
	script := fmt.Sprintf("set -e\nps -eo pid=,args= | awk '/[[:space:]]a3 execute-until-idle/ && !/awk/ { print $1 }' | xargs -r kill >/dev/null 2>&1 || true\nps -eo pid=,args= | awk '/[[:space:]]a3 agent-server/ && !/awk/ { print $1 }' | xargs -r kill >/dev/null 2>&1 || true\nif [ -f %s ]; then kill \"$(cat %s)\" >/dev/null 2>&1 || true; rm -f %s; fi\nif [ -f %s ]; then kill \"$(cat %s)\" >/dev/null 2>&1 || true; rm -f %s; fi\nrm -f %s %s %s\n", shellQuote(plan.RuntimePIDFile), shellQuote(plan.RuntimePIDFile), shellQuote(plan.RuntimePIDFile), shellQuote(plan.ServerPIDFile), shellQuote(plan.ServerPIDFile), shellQuote(plan.ServerPIDFile), shellQuote(plan.RuntimeExitFile), shellQuote(plan.ServerLog), shellQuote(plan.RuntimeLog))
	_, err := runExternal(runner, "docker", append(plan.ComposePrefix, "exec", "-T", config.RuntimeService, "bash", "-lc", script)...)
	return err
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

func startRuntimeAgentServer(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer) error {
	fmt.Fprintf(stdout, "runtime_agent_server_start port=%s\n", plan.AgentPort)
	script := fmt.Sprintf("cd /workspace && a3 agent-server --storage-dir %s --host 0.0.0.0 --port %s > %s 2>&1 & echo $! > %s", shellQuote(plan.StorageDir), shellQuote(plan.AgentPort), shellQuote(plan.ServerLog), shellQuote(plan.ServerPIDFile))
	_, err := runExternal(runner, "docker", append(plan.ComposePrefix, "exec", "-T", config.RuntimeService, "bash", "-lc", script)...)
	return err
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
	args := executeUntilIdleArgs(plan)
	command := "cd /workspace && (export A3_ROOT_DIR=/workspace KANBAN_BACKEND=soloboard A3_BRANCH_NAMESPACE=" + shellQuote(plan.BranchNamespace) + " A3_SECRET_REFERENCE=\"${A3_SECRET_REFERENCE:-A3_SECRET}\" A3_SECRET=\"${A3_SECRET:-portal-runtime-secret}\"; " + shellJoin(args) + " > " + shellQuote(plan.RuntimeLog) + " 2>&1; echo $? > " + shellQuote(plan.RuntimeExitFile) + ") & echo $! > " + shellQuote(plan.RuntimePIDFile)
	_, err := runExternal(runner, "docker", append(plan.ComposePrefix, "exec", "-T", config.RuntimeService, "bash", "-lc", command)...)
	return err
}

func executeUntilIdleArgs(plan runtimeRunOncePlan) []string {
	args := []string{
		"a3", "execute-until-idle",
		"--preset-dir", "a3-engine/config/presets",
		"--storage-backend", "json",
		"--storage-dir", plan.StorageDir,
		"--worker-gateway", "agent-http",
		"--verification-command-runner", "agent-http",
		"--merge-runner", "agent-http",
		"--agent-control-plane-url", "http://127.0.0.1:" + plan.AgentPort,
		"--agent-runtime-profile", "host-local",
		"--agent-shared-workspace-mode", "agent-materialized",
		"--agent-support-ref", envDefault("A3_RUNTIME_RUN_ONCE_LIVE_REF", envDefault("A3_RUNTIME_SCHEDULER_LIVE_REF", "refs/heads/feature/prototype")),
		"--agent-env", "A3_ROOT_DIR=" + plan.HostRootDir,
		"--agent-env", "A3_WORKER_LAUNCHER_CONFIG_PATH=" + filepath.Join(plan.HostRootDir, "scripts/a3-projects/portal/inject/config/portal/launcher.json"),
		"--agent-env", "A3_MAVEN_WORKSPACE_BOOTSTRAP_MODE=" + envDefault("A3_RUNTIME_RUN_ONCE_MAVEN_WORKSPACE_BOOTSTRAP_MODE", envDefault("A3_RUNTIME_SCHEDULER_MAVEN_WORKSPACE_BOOTSTRAP_MODE", "empty")),
		"--agent-workspace-root", plan.WorkspaceRoot,
		"--agent-source-path", "member-portal-starters=" + filepath.Join(plan.HostRootDir, "member-portal-starters"),
		"--agent-source-path", "member-portal-ui-app=" + filepath.Join(plan.HostRootDir, "member-portal-ui-app"),
		"--agent-required-bin", "git",
		"--agent-required-bin", "task",
		"--agent-required-bin", "ruby",
		"--agent-source-alias", "repo_alpha=member-portal-starters",
		"--agent-source-alias", "repo_beta=member-portal-ui-app",
		"--agent-workspace-cleanup-policy", "cleanup_after_job",
		"--agent-job-timeout-seconds", plan.JobTimeoutSeconds,
		"--agent-job-poll-interval-seconds", "1.0",
		"--worker-command", plan.WorkerCommand,
	}
	for _, workerArg := range plan.WorkerArgs {
		args = append(args, "--worker-command-arg", workerArg)
	}
	args = append(args,
		"--kanban-command", "python3",
		"--kanban-command-arg", "a3-engine/tools/kanban/cli.py",
		"--kanban-command-arg", "--backend",
		"--kanban-command-arg", "soloboard",
		"--kanban-command-arg", "--base-url",
		"--kanban-command-arg", plan.SoloBoardInternalURL,
		"--kanban-project", "Portal",
		"--kanban-status", "To do",
		"--kanban-working-dir", "/workspace",
		"--kanban-follow-up-label", "a3:follow-up-child",
		"--kanban-repo-label", "repo:starters=repo_alpha",
		"--kanban-repo-label", "repo:ui-app=repo_beta",
		"--kanban-repo-label", "repo:both=repo_alpha,repo_beta",
		"--kanban-trigger-label", "trigger:auto-implement",
		"--kanban-trigger-label", "trigger:auto-parent",
		"--repo-source", "repo_alpha=/workspace/member-portal-starters",
		"--repo-source", "repo_beta=/workspace/member-portal-ui-app",
		"--max-steps", plan.MaxSteps,
		plan.ManifestPath,
	)
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
			args = append(args,
				"-workspace-root", plan.WorkspaceRoot,
				"-source-alias", "member-portal-starters="+filepath.Join(plan.HostRootDir, "member-portal-starters"),
				"-source-alias", "member-portal-ui-app="+filepath.Join(plan.HostRootDir, "member-portal-ui-app"),
			)
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
	output, err := runExternal(runner, "docker", append(plan.ComposePrefix, "exec", "-T", config.RuntimeService, "bash", "-lc", "cat "+shellQuote(plan.RuntimeExitFile))...)
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
	script := fmt.Sprintf("echo '--- runtime log ---'; tail -n 220 %s || true; echo '--- server log ---'; tail -n 120 %s || true", shellQuote(plan.RuntimeLog), shellQuote(plan.ServerLog))
	output, err := runExternal(runner, "docker", append(plan.ComposePrefix, "exec", "-T", config.RuntimeService, "bash", "-lc", script)...)
	fmt.Fprint(stdout, string(output))
	return err
}

func printRuntimeSuccessTail(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer) error {
	script := fmt.Sprintf("echo '--- runtime log tail ---'; tail -n 160 %s || true", shellQuote(plan.RuntimeLog))
	output, err := runExternal(runner, "docker", append(plan.ComposePrefix, "exec", "-T", config.RuntimeService, "bash", "-lc", script)...)
	fmt.Fprint(stdout, string(output))
	return err
}

func runRuntimeLoop(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a3 runtime loop", flag.ContinueOnError)
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
		fmt.Fprintf(stdout, "runtime_loop_cycle_start cycle=%d\n", cycle)
		if err := runRuntimeRunOnce(buildRunOnceArgs(*maxSteps, *agentAttempts), runner, stdout, stderr); err != nil {
			return fmt.Errorf("runtime loop cycle %d failed: %w", cycle, err)
		}
		fmt.Fprintf(stdout, "runtime_loop_cycle_done cycle=%d\n", cycle)
		if *maxCycles > 0 && cycle >= *maxCycles {
			fmt.Fprintf(stdout, "runtime_loop_finished cycles=%d\n", cycle)
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

func runAgent(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "missing agent subcommand")
		printUsage(stderr)
		return 2
	}

	switch args[0] {
	case "target":
		target, err := detectHostTarget()
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 2
		}
		fmt.Fprintln(stdout, target)
		return 0
	case "install":
		if err := runAgentInstall(args[1:], runner, stdout, stderr); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	default:
		fmt.Fprintf(stderr, "unknown agent subcommand: %s\n", args[0])
		printUsage(stderr)
		return 2
	}
}

func runAgentInstall(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a3 agent install", flag.ContinueOnError)
	flags.SetOutput(stderr)

	target := flags.String("target", "auto", "agent package target, or auto")
	output := flags.String("output", "", "host output path for the exported a3-agent binary")
	composeProject := flags.String("compose-project", "", "docker compose project name")
	composeFile := flags.String("compose-file", "", "docker compose file")
	runtimeService := flags.String("runtime-service", "", "docker compose runtime service name")
	runtimeOutput := flags.String("runtime-output", "/tmp/a3-agent-export", "temporary output path inside the runtime container")
	build := flags.Bool("build", false, "build the runtime image before exporting the agent")

	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	if strings.TrimSpace(*output) == "" {
		return errors.New("--output is required")
	}

	resolvedTarget := strings.TrimSpace(*target)
	if resolvedTarget == "" || resolvedTarget == "auto" {
		detected, err := detectHostTarget()
		if err != nil {
			return err
		}
		resolvedTarget = detected
	}

	outputPath, err := filepath.Abs(*output)
	if err != nil {
		return fmt.Errorf("resolve output path: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(outputPath), 0o755); err != nil {
		return fmt.Errorf("create output directory: %w", err)
	}

	instanceConfig, _, instanceConfigErr := loadInstanceConfigFromWorkingTree()
	if instanceConfigErr != nil && strings.TrimSpace(*composeProject) == "" && strings.TrimSpace(*composeFile) == "" {
		return instanceConfigErr
	}
	config := runtimeInstanceConfig{}
	if instanceConfig != nil {
		config = *instanceConfig
	}
	config = applyAgentInstallOverrides(config, *composeProject, *composeFile, *runtimeService)

	composePrefix := composeArgs(config)
	if *build {
		if _, err := runExternal(runner, "docker", append(composePrefix, "build", config.RuntimeService)...); err != nil {
			return err
		}
	}
	var containerID string
	err = withComposeEnv(config, func() error {
		if _, err := runExternal(runner, "docker", append(composePrefix, "up", "-d", "--no-deps", config.RuntimeService)...); err != nil {
			return err
		}
		containerBytes, err := runExternal(runner, "docker", append(composePrefix, "ps", "-q", config.RuntimeService)...)
		if err != nil {
			return err
		}
		containerID = strings.TrimSpace(string(containerBytes))
		if containerID == "" {
			return fmt.Errorf("runtime container not found for service %q", config.RuntimeService)
		}
		return nil
	})
	if err != nil {
		return err
	}

	if _, err := runExternal(runner, "docker", "exec", containerID, "a3", "agent", "package", "verify", "--target", resolvedTarget); err != nil {
		return err
	}
	if _, err := runExternal(runner, "docker", "exec", containerID, "a3", "agent", "package", "export", "--target", resolvedTarget, "--output", *runtimeOutput); err != nil {
		return err
	}
	if _, err := runExternal(runner, "docker", "cp", containerID+":"+*runtimeOutput, outputPath); err != nil {
		return err
	}
	if err := os.Chmod(outputPath, 0o755); err != nil {
		return fmt.Errorf("chmod exported agent: %w", err)
	}

	fmt.Fprintf(stdout, "agent_installed target=%s output=%s\n", resolvedTarget, outputPath)
	return nil
}

func runExternal(runner commandRunner, name string, args ...string) ([]byte, error) {
	output, err := runner.Run(name, args...)
	if err == nil {
		return output, nil
	}
	command := strings.TrimSpace(name + " " + strings.Join(args, " "))
	message := strings.TrimSpace(string(output))
	if message == "" {
		return nil, fmt.Errorf("%s failed: %w", command, err)
	}
	return nil, fmt.Errorf("%s failed: %w\n%s", command, err, message)
}

func detectHostTarget() (string, error) {
	var osPart string
	switch runtime.GOOS {
	case "darwin", "linux":
		osPart = runtime.GOOS
	default:
		return "", fmt.Errorf("unsupported host OS: %s", runtime.GOOS)
	}

	var archPart string
	switch runtime.GOARCH {
	case "amd64", "arm64":
		archPart = runtime.GOARCH
	default:
		return "", fmt.Errorf("unsupported host architecture: %s", runtime.GOARCH)
	}

	return osPart + "-" + archPart, nil
}

func envDefault(name string, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func envDefaultValue(value string, fallback string) string {
	if strings.TrimSpace(value) != "" {
		return strings.TrimSpace(value)
	}
	return fallback
}

func parsePositiveInt(value string, label string) (int, error) {
	parsed, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil {
		return 0, fmt.Errorf("parse %s: %w", label, err)
	}
	if parsed <= 0 {
		return 0, fmt.Errorf("%s must be > 0", label)
	}
	return parsed, nil
}

func resolveDefaultHostAgentBin(config runtimeInstanceConfig, hostRootDir string) string {
	publicAgentPath := filepath.Join(hostRootDir, ".work", "a2o-agent", "bin", "a2o-agent")
	if _, err := os.Stat(publicAgentPath); err == nil {
		return publicAgentPath
	}
	if strings.TrimSpace(config.WorkspaceRoot) != "" && config.WorkspaceRoot != hostRootDir {
		publicWorkspaceAgentPath := filepath.Join(config.WorkspaceRoot, ".work", "a2o-agent", "bin", "a2o-agent")
		if _, err := os.Stat(publicWorkspaceAgentPath); err == nil {
			return publicWorkspaceAgentPath
		}
	}
	return filepath.Join(hostRootDir, ".work", "a3-agent", "bin", "a3-agent")
}

func shellQuote(value string) string {
	if value == "" {
		return "''"
	}
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

func shellJoin(args []string) string {
	quoted := make([]string, 0, len(args))
	for _, arg := range args {
		quoted = append(quoted, shellQuote(arg))
	}
	return strings.Join(quoted, " ")
}

func appendFile(path string, body []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer file.Close()
	_, err = file.Write(body)
	return err
}

func defaultComposeFile() string {
	candidates := []string{}
	if executablePath, err := os.Executable(); err == nil {
		executableDir := filepath.Dir(executablePath)
		candidates = append(
			candidates,
			filepath.Join(executableDir, "..", "share", "a2o", "docker", "compose", "a3-portal-soloboard.yml"),
			filepath.Join(executableDir, "..", "share", "a3", "docker", "compose", "a3-portal-soloboard.yml"),
		)
	}
	candidates = append(candidates,
		"a3-engine/docker/compose/a3-portal-soloboard.yml",
		"docker/compose/a3-portal-soloboard.yml",
		"../docker/compose/a3-portal-soloboard.yml",
		"../share/a2o/docker/compose/a3-portal-soloboard.yml",
		"../share/a3/docker/compose/a3-portal-soloboard.yml",
	)
	for _, candidate := range candidates {
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return candidates[0]
}

func defaultRuntimeImage() string {
	if value := strings.TrimSpace(os.Getenv("A3_RUNTIME_IMAGE")); value != "" {
		return value
	}
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
		candidate := filepath.Join(current, instanceConfigRelativePath)
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		}
		parent := filepath.Dir(current)
		if parent == current {
			return "", fmt.Errorf("A3 runtime instance config not found; run `a2o project bootstrap --package ./a2o-project` first")
		}
		current = parent
	}
}

func readInstanceConfig(path string) (*runtimeInstanceConfig, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read instance config: %w", err)
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
	return "a3-" + normalized
}

func applyAgentInstallOverrides(config runtimeInstanceConfig, composeProject string, composeFile string, runtimeService string) runtimeInstanceConfig {
	if strings.TrimSpace(config.ComposeProject) == "" {
		config.ComposeProject = envDefault("A3_COMPOSE_PROJECT", "a3-portal-bundle")
	}
	if strings.TrimSpace(config.ComposeFile) == "" {
		config.ComposeFile = envDefault("A3_COMPOSE_FILE", defaultComposeFile())
	}
	if strings.TrimSpace(config.RuntimeService) == "" {
		config.RuntimeService = envDefault("A3_RUNTIME_SERVICE", "a3-runtime")
	}
	if envComposeProject := strings.TrimSpace(os.Getenv("A3_COMPOSE_PROJECT")); envComposeProject != "" {
		config.ComposeProject = envComposeProject
	}
	if envComposeFile := strings.TrimSpace(os.Getenv("A3_COMPOSE_FILE")); envComposeFile != "" {
		config.ComposeFile = envComposeFile
	}
	if envRuntimeService := strings.TrimSpace(os.Getenv("A3_RUNTIME_SERVICE")); envRuntimeService != "" {
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
	return config
}

func composeArgs(config runtimeInstanceConfig) []string {
	config = applyAgentInstallOverrides(config, "", "", "")
	return []string{"compose", "-p", config.ComposeProject, "-f", config.ComposeFile}
}

func withComposeEnv(config runtimeInstanceConfig, fn func() error) error {
	return withEnv(composeEnv(config), fn)
}

func composeEnv(config runtimeInstanceConfig) map[string]string {
	overrides := map[string]string{}
	if soloboardPort := envDefault("A3_BUNDLE_SOLOBOARD_PORT", config.SoloBoardPort); strings.TrimSpace(soloboardPort) != "" {
		overrides["A3_BUNDLE_SOLOBOARD_PORT"] = soloboardPort
	}
	if agentPort := envDefault("A3_BUNDLE_AGENT_PORT", config.AgentPort); strings.TrimSpace(agentPort) != "" {
		overrides["A3_BUNDLE_AGENT_PORT"] = agentPort
	}
	if strings.TrimSpace(config.WorkspaceRoot) != "" {
		overrides["A3_WORKSPACE_ROOT"] = config.WorkspaceRoot
		overrides["A3_HOST_WORKSPACE_ROOT"] = config.WorkspaceRoot
	}
	if runtimeImage := defaultRuntimeImage(); runtimeImage != "" {
		overrides["A3_RUNTIME_IMAGE"] = runtimeImage
	}
	return overrides
}

func runtimeRunOnceEnv(config runtimeInstanceConfig, maxSteps string, agentAttempts string) map[string]string {
	overrides := composeEnv(config)
	overrides["A3_PORTAL_BUNDLE_COMPOSE_FILE"] = config.ComposeFile
	overrides["A3_PORTAL_BUNDLE_PROJECT"] = config.ComposeProject
	if storageDir := envDefault("PORTAL_A3_BUNDLE_STORAGE_DIR", config.StorageDir); strings.TrimSpace(storageDir) != "" {
		overrides["PORTAL_A3_BUNDLE_STORAGE_DIR"] = storageDir
	}
	if strings.TrimSpace(config.WorkspaceRoot) != "" {
		overrides["A3_RUNTIME_RUN_ONCE_HOST_ROOT_DIR"] = config.WorkspaceRoot
		overrides["A3_RUNTIME_RUN_ONCE_HOST_ROOT"] = filepath.Join(config.WorkspaceRoot, ".work", "a3", "runtime-host-agent")
		overrides["A3_RUNTIME_RUN_ONCE_AGENT_WORKSPACE_ROOT"] = filepath.Join(config.WorkspaceRoot, ".work", "a3", "runtime-host-agent", "workspaces")
		publicAgentPath := filepath.Join(config.WorkspaceRoot, ".work", "a2o-agent", "bin", "a2o-agent")
		if _, err := os.Stat(publicAgentPath); err == nil {
			overrides["A3_HOST_AGENT_BIN"] = publicAgentPath
		} else {
			overrides["A3_HOST_AGENT_BIN"] = filepath.Join(config.WorkspaceRoot, ".work", "a3-agent", "bin", "a3-agent")
		}
	}
	if strings.TrimSpace(config.ComposeProject) != "" {
		overrides["A3_BRANCH_NAMESPACE"] = config.ComposeProject
	}
	if strings.TrimSpace(maxSteps) != "" {
		overrides["A3_RUNTIME_RUN_ONCE_MAX_STEPS"] = strings.TrimSpace(maxSteps)
	}
	if strings.TrimSpace(agentAttempts) != "" {
		overrides["A3_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS"] = strings.TrimSpace(agentAttempts)
	}
	return overrides
}

func runWithEnv(overrides map[string]string, fn func() ([]byte, error)) ([]byte, error) {
	var output []byte
	err := withEnv(overrides, func() error {
		var runErr error
		output, runErr = fn()
		return runErr
	})
	return output, err
}

func withEnv(overrides map[string]string, fn func() error) error {
	originals := make(map[string]*string, len(overrides))
	for key, value := range overrides {
		if current, ok := os.LookupEnv(key); ok {
			copyValue := current
			originals[key] = &copyValue
		} else {
			originals[key] = nil
		}
		if err := os.Setenv(key, value); err != nil {
			return err
		}
	}
	defer func() {
		for key, value := range originals {
			if value == nil {
				_ = os.Unsetenv(key)
			} else {
				_ = os.Setenv(key, *value)
			}
		}
	}()
	return fn()
}
