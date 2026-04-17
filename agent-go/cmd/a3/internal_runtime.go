package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Internal runtime helpers are intentionally kept outside the public command
// router. They remain available to tests and future maintenance wiring without
// advertising a runtime command as part of the A2O host launcher surface.
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
