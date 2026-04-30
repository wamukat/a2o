package main

import (
	"bytes"
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

func runRuntimeDecomposition(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	if len(args) == 0 || isHelpArg(args[0]) {
		printRuntimeDecompositionUsage(stdout)
		return nil
	}
	action := args[0]
	if len(args) >= 2 && isHelpArg(args[1]) {
		return printRuntimeDecompositionActionUsage(stdout, action)
	}
	flags := flag.NewFlagSet("a2o runtime decomposition "+action, flag.ContinueOnError)
	flags.SetOutput(stderr)
	projectKey := flags.String("project", "", "runtime project key")
	projectConfig := flags.String("project-config", "", "explicit project config file, for example project-test.yaml")
	gate := flags.Bool("gate", false, "allow create-children to write child tickets")
	applyCleanup := flags.Bool("apply", false, "apply decomposition cleanup")
	dryRunCleanup := flags.Bool("dry-run", false, "preview decomposition cleanup")
	investigationEvidencePath := flags.String("investigation-evidence-path", "", "proposal input evidence path")
	proposalEvidencePath := flags.String("proposal-evidence-path", "", "proposal evidence path")
	reviewEvidencePath := flags.String("review-evidence-path", "", "proposal review evidence path")
	var repoSources stringListFlag
	flags.Var(&repoSources, "repo-source", "repo source mapping SLOT=PATH; may be repeated")
	flagArgs, positionals, err := splitRuntimeDecompositionArgs(action, args[1:])
	if err != nil {
		return err
	}
	if err := flags.Parse(flagArgs); err != nil {
		return err
	}
	if action == "cleanup" && *applyCleanup && *dryRunCleanup {
		return fmt.Errorf("runtime decomposition cleanup accepts only one of --dry-run or --apply")
	}
	if len(positionals) != 1 {
		return fmt.Errorf("usage: a2o runtime decomposition %s TASK_REF", action)
	}
	resolvedProject, taskRef, err := resolveRuntimeProjectTaskRef(*projectKey, positionals[0])
	if err != nil {
		return err
	}

	context, configPath, err := loadProjectRuntimeContextForCommand(resolvedProject, true)
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(context.Config, "", "", "")
	plan, err := buildRuntimeRunOncePlan(effectiveConfig, runtimeRunOnceOverrides{}, *projectConfig)
	if err != nil {
		return err
	}
	command, err := runtimeDecompositionCommand(action, taskRef, plan, normalizeRuntimeDecompositionRepoSources(plan, repoSources), runtimeDecompositionOverrides{
		Gate:                      *gate,
		ApplyCleanup:              *applyCleanup,
		InvestigationEvidencePath: *investigationEvidencePath,
		ProposalEvidencePath:      *proposalEvidencePath,
		ReviewEvidencePath:        *reviewEvidencePath,
	})
	if err != nil {
		return err
	}

	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", publicInstanceConfigPath(configPath))
	fmt.Fprintf(stdout, "runtime_project_key=%s\n", context.ProjectKey)
	fmt.Fprintf(stdout, "runtime_storage=internal-managed project_config=%s surface_source=project-package\n", plan.ManifestPath)
	if runtimeDecompositionUsesHostAgent(action) {
		return runRuntimeDecompositionWithHostAgent(effectiveConfig, plan, command, action, runner, stdout)
	}
	output, err := dockerComposeExecOutput(effectiveConfig, plan, runner, runtimeInspectionArgs(command...)...)
	if err != nil {
		return fmt.Errorf("runtime decomposition %s failed: %w", action, err)
	}
	fmt.Fprint(stdout, string(output))
	if len(output) == 0 || output[len(output)-1] != '\n' {
		fmt.Fprintln(stdout)
	}
	return nil
}

func runtimeDecompositionUsesHostAgent(action string) bool {
	return action == "investigate" || action == "propose" || action == "review"
}

func runRuntimeDecompositionWithHostAgent(config runtimeInstanceConfig, plan runtimeRunOncePlan, command []string, action string, runner commandRunner, stdout io.Writer) error {
	return withComposeEnv(config, func() error {
		services := []string{config.RuntimeService}
		if !isExternalKanban(config) {
			services = append(services, "kanbalone")
		}
		if _, err := runExternal(runner, "docker", append(plan.ComposePrefix, append([]string{"up", "-d"}, services...)...)...); err != nil {
			return err
		}
		decompositionPlan := decompositionRuntimeProcessPlan(config, plan, action)
		if err := cleanupRuntimeProcesses(config, decompositionPlan, runner); err != nil {
			return err
		}
		if err := ensureRuntimeLauncherConfig(plan, stdout); err != nil {
			return err
		}
		if err := ensureRuntimeHostAgent(config, plan, runner, stdout); err != nil {
			return err
		}
		if err := startRuntimeAgentServerUnlessReady(config, plan, runner, stdout); err != nil {
			return err
		}
		if err := waitForRuntimeControlPlane(plan, runner); err != nil {
			return err
		}
		if err := startRuntimeDecompositionCommand(config, decompositionPlan, command, action, runner, stdout); err != nil {
			return err
		}
		if err := runHostAgentLoop(config, decompositionPlan, runner, stdout); err != nil {
			output := dockerComposeExecBestEffort(config, decompositionPlan, runner, "cat", decompositionPlan.RuntimeLog)
			if len(output) > 0 {
				fmt.Fprint(stdout, string(output))
				if output[len(output)-1] != '\n' {
					fmt.Fprintln(stdout)
				}
			}
			_ = cleanupRuntimeProcesses(config, decompositionPlan, runner)
			return err
		}
		exit, err := readRuntimeExit(config, decompositionPlan, runner)
		if err != nil {
			return err
		}
		output := dockerComposeExecBestEffort(config, decompositionPlan, runner, "cat", decompositionPlan.RuntimeLog)
		fmt.Fprint(stdout, string(output))
		if len(output) == 0 || output[len(output)-1] != '\n' {
			fmt.Fprintln(stdout)
		}
		if exit != "0" {
			return fmt.Errorf("runtime decomposition %s failed with exit=%s", action, exit)
		}
		return cleanupRuntimeProcesses(config, decompositionPlan, runner)
	})
}

func decompositionRuntimeProcessPlan(config runtimeInstanceConfig, plan runtimeRunOncePlan, action string) runtimeRunOncePlan {
	suffix := "decomposition-" + safeProjectKeyComponent(action)
	plan.RuntimeLog = runtimeProjectTempPath(config, suffix+".log")
	plan.RuntimeExitFile = runtimeProjectTempPath(config, suffix+".exit")
	plan.RuntimePIDFile = runtimeProjectTempPath(config, suffix+".pid")
	return plan
}

func splitRuntimeDecompositionArgs(action string, args []string) ([]string, []string, error) {
	var flagArgs []string
	var positionals []string
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "--gate":
			flagArgs = append(flagArgs, arg)
		case action == "cleanup" && (arg == "--apply" || arg == "--dry-run"):
			flagArgs = append(flagArgs, arg)
		case arg == "--project" || arg == "--project-config" || arg == "--repo-source" || arg == "--investigation-evidence-path" || arg == "--proposal-evidence-path" || arg == "--review-evidence-path":
			if i+1 >= len(args) {
				return nil, nil, fmt.Errorf("%s requires a value", arg)
			}
			flagArgs = append(flagArgs, arg, args[i+1])
			i++
		case strings.HasPrefix(arg, "--project=") || strings.HasPrefix(arg, "--project-config=") || strings.HasPrefix(arg, "--repo-source=") || strings.HasPrefix(arg, "--investigation-evidence-path=") || strings.HasPrefix(arg, "--proposal-evidence-path=") || strings.HasPrefix(arg, "--review-evidence-path="):
			flagArgs = append(flagArgs, arg)
		case strings.HasPrefix(arg, "-"):
			return nil, nil, fmt.Errorf("unknown runtime decomposition option: %s", arg)
		default:
			positionals = append(positionals, arg)
		}
	}
	return flagArgs, positionals, nil
}

type runtimeDecompositionOverrides struct {
	Gate                      bool
	ApplyCleanup              bool
	InvestigationEvidencePath string
	ProposalEvidencePath      string
	ReviewEvidencePath        string
}

func runtimeDecompositionCommand(action string, taskRef string, plan runtimeRunOncePlan, repoSources []string, overrides runtimeDecompositionOverrides) ([]string, error) {
	args := []string{"a3"}
	switch action {
	case "investigate":
		args = append(args, "run-decomposition-investigation", taskRef, plan.ManifestPath)
		args = append(args, runtimeDecompositionRuntimeOptions(plan)...)
		args = append(args, runtimeDecompositionHostAgentOptions(plan)...)
		args = append(args, runtimeDecompositionKanbanOptions(plan)...)
		args = append(args, runtimeDecompositionRepoSourceOptions(repoSources, plan.RepoSources)...)
	case "propose":
		args = append(args, "run-decomposition-proposal-author", taskRef, plan.ManifestPath)
		args = append(args, runtimeDecompositionRuntimeOptions(plan)...)
		args = append(args, runtimeDecompositionHostAgentOptions(plan)...)
		if strings.TrimSpace(overrides.InvestigationEvidencePath) != "" {
			args = append(args, "--investigation-evidence-path", workspaceContainerPath(plan.HostRootDir, overrides.InvestigationEvidencePath))
		}
		args = append(args, runtimeDecompositionKanbanOptions(plan)...)
		args = append(args, runtimeDecompositionRepoSourceOptions(repoSources, plan.RepoSources)...)
	case "review":
		args = append(args, "run-decomposition-proposal-review", taskRef, plan.ManifestPath)
		args = append(args, runtimeDecompositionRuntimeOptions(plan)...)
		args = append(args, runtimeDecompositionHostAgentOptions(plan)...)
		if strings.TrimSpace(overrides.ProposalEvidencePath) != "" {
			args = append(args, "--proposal-evidence-path", workspaceContainerPath(plan.HostRootDir, overrides.ProposalEvidencePath))
		}
		args = append(args, runtimeDecompositionKanbanOptions(plan)...)
		args = append(args, runtimeDecompositionRepoSourceOptions(repoSources, plan.RepoSources)...)
	case "create-children":
		args = append(args, "run-decomposition-child-creation", taskRef)
		args = append(args, "--storage-backend", "json", "--storage-dir", plan.StorageDir)
		if strings.TrimSpace(overrides.ProposalEvidencePath) != "" {
			args = append(args, "--proposal-evidence-path", workspaceContainerPath(plan.HostRootDir, overrides.ProposalEvidencePath))
		}
		if strings.TrimSpace(overrides.ReviewEvidencePath) != "" {
			args = append(args, "--review-evidence-path", workspaceContainerPath(plan.HostRootDir, overrides.ReviewEvidencePath))
		}
		args = append(args, runtimeDecompositionKanbanOptions(plan)...)
		if overrides.Gate {
			args = append(args, "--gate")
		}
	case "status":
		args = append(args, "show-decomposition-status", taskRef, "--storage-backend", "json", "--storage-dir", plan.StorageDir)
	case "cleanup":
		args = append(args, "cleanup-decomposition-trial", taskRef, "--storage-backend", "json", "--storage-dir", plan.StorageDir)
		if overrides.ApplyCleanup {
			args = append(args, "--apply")
		}
	default:
		return nil, fmt.Errorf("unknown runtime decomposition subcommand: %s", action)
	}
	return args, nil
}

func printRuntimeDecompositionUsage(w io.Writer) {
	fmt.Fprintln(w, "usage: a2o runtime decomposition investigate|propose|review|create-children|status|cleanup [--project KEY] TASK_REF [--project-config project-test.yaml]")
	fmt.Fprintln(w, "actions:")
	fmt.Fprintln(w, "  investigate       run the configured decomposition investigation command")
	fmt.Fprintln(w, "  propose           create proposal evidence from investigation evidence")
	fmt.Fprintln(w, "  review            review proposal evidence")
	fmt.Fprintln(w, "  create-children   create or reconcile Kanban child tickets; requires --gate")
	fmt.Fprintln(w, "  status            show local decomposition evidence status")
	fmt.Fprintln(w, "  cleanup           list or remove local decomposition trial evidence/workspaces")
}

func printRuntimeDecompositionActionUsage(w io.Writer, action string) error {
	switch action {
	case "investigate":
		fmt.Fprintln(w, "usage: a2o runtime decomposition investigate [--project KEY] TASK_REF [--project-config project-test.yaml] [--repo-source SLOT=PATH]")
	case "propose":
		fmt.Fprintln(w, "usage: a2o runtime decomposition propose [--project KEY] TASK_REF [--project-config project-test.yaml] [--investigation-evidence-path PATH]")
	case "review":
		fmt.Fprintln(w, "usage: a2o runtime decomposition review [--project KEY] TASK_REF [--project-config project-test.yaml] [--proposal-evidence-path PATH]")
	case "create-children":
		fmt.Fprintln(w, "usage: a2o runtime decomposition create-children [--project KEY] TASK_REF [--project-config project-test.yaml] [--proposal-evidence-path PATH] [--review-evidence-path PATH] [--gate]")
	case "status":
		fmt.Fprintln(w, "usage: a2o runtime decomposition status [--project KEY] TASK_REF [--project-config project-test.yaml]")
	case "cleanup":
		fmt.Fprintln(w, "usage: a2o runtime decomposition cleanup [--project KEY] TASK_REF [--project-config project-test.yaml] [--dry-run|--apply]")
	default:
		return fmt.Errorf("unknown runtime decomposition subcommand: %s", action)
	}
	return nil
}

func runtimeDecompositionRuntimeOptions(plan runtimeRunOncePlan) []string {
	return []string{"--storage-backend", "json", "--storage-dir", plan.StorageDir, "--preset-dir", plan.PresetDir}
}

func runtimeDecompositionHostAgentOptions(plan runtimeRunOncePlan) []string {
	args := []string{
		"--decomposition-command-runner", "agent-http",
		"--agent-control-plane-url", "http://127.0.0.1:" + plan.AgentInternalPort,
		"--agent-runtime-profile", "host-local",
		"--agent-job-timeout-seconds", plan.JobTimeoutSeconds,
		"--agent-job-poll-interval-seconds", "1.0",
		"--host-shared-root", plan.HostRootDir,
		"--container-shared-root", "/workspace",
		"--decomposition-workspace-dir", "/workspace/.work/a2o/decomposition-workspaces",
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
	return args
}

func runtimeDecompositionKanbanOptions(plan runtimeRunOncePlan) []string {
	args := runtimeDecompositionKanbanWriteOptions(plan)
	args = append(args, "--kanban-status", plan.KanbanStatus)
	for _, repoLabel := range plan.KanbanRepoLabels {
		args = append(args, "--kanban-repo-label", repoLabel)
	}
	return args
}

func runtimeDecompositionKanbanWriteOptions(plan runtimeRunOncePlan) []string {
	return []string{
		"--kanban-command", "python3",
		"--kanban-command-arg", packagedKanbanCLIPath,
		"--kanban-command-arg", "--backend",
		"--kanban-command-arg", "kanbalone",
		"--kanban-command-arg", "--base-url",
		"--kanban-command-arg", plan.SoloBoardInternalURL,
		"--kanban-project", plan.KanbanProject,
		"--kanban-working-dir", "/workspace",
	}
}

func runtimeDecompositionRepoSourceOptions(explicit []string, defaults []string) []string {
	sources := explicit
	if len(sources) == 0 {
		sources = defaults
	}
	args := make([]string, 0, len(sources)*2)
	for _, repoSource := range sources {
		args = append(args, "--repo-source", repoSource)
	}
	return args
}

func normalizeRuntimeDecompositionRepoSources(plan runtimeRunOncePlan, repoSources []string) []string {
	if len(repoSources) == 0 {
		return nil
	}
	normalized := make([]string, 0, len(repoSources))
	for _, repoSource := range repoSources {
		slot, sourcePath, ok := strings.Cut(repoSource, "=")
		if !ok {
			normalized = append(normalized, repoSource)
			continue
		}
		normalized = append(normalized, slot+"="+workspaceContainerPath(plan.HostRootDir, sourcePath))
	}
	return normalized
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

type runtimeResumeOptions struct {
	Interval                        string
	MaxSteps                        string
	AgentAttempts                   string
	AgentPollInterval               string
	AgentControlPlaneConnectTimeout string
	AgentControlPlaneRequestTimeout string
	AgentControlPlaneRetries        string
	AgentControlPlaneRetryDelay     string
}

func runRuntimeResume(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime resume", flag.ContinueOnError)
	flags.SetOutput(stderr)
	interval := flags.String("interval", "60s", "duration between scheduler cycles")
	maxSteps := flags.String("max-steps", "", "maximum runtime steps for each cycle")
	agentAttempts := flags.String("agent-attempts", "", "maximum host agent attempts for each cycle")
	agentPollInterval := flags.String("agent-poll-interval", "", "idle duration between host agent polls during each cycle")
	agentControlPlaneConnectTimeout := flags.String("agent-control-plane-connect-timeout", "", "TCP connect timeout for host agent control plane requests during each cycle")
	agentControlPlaneRequestTimeout := flags.String("agent-control-plane-request-timeout", "", "per-request timeout for host agent control plane requests during each cycle")
	agentControlPlaneRetries := flags.String("agent-control-plane-retries", "", "retry count for transient host agent control plane request failures during each cycle")
	agentControlPlaneRetryDelay := flags.String("agent-control-plane-retry-delay", "", "delay between transient host agent control plane retries during each cycle")
	projectKey := flags.String("project", "", "runtime project key")
	allProjects := flags.Bool("all-projects", false, "resume schedulers for every project in the runtime project registry")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	if *allProjects && strings.TrimSpace(*projectKey) != "" {
		return fmt.Errorf("--all-projects cannot be combined with --project")
	}
	options := runtimeResumeOptions{
		Interval:                        *interval,
		MaxSteps:                        *maxSteps,
		AgentAttempts:                   *agentAttempts,
		AgentPollInterval:               *agentPollInterval,
		AgentControlPlaneConnectTimeout: *agentControlPlaneConnectTimeout,
		AgentControlPlaneRequestTimeout: *agentControlPlaneRequestTimeout,
		AgentControlPlaneRetries:        *agentControlPlaneRetries,
		AgentControlPlaneRetryDelay:     *agentControlPlaneRetryDelay,
	}
	if err := validateRuntimeResumeOptions(options); err != nil {
		return err
	}
	if *allProjects {
		return runRuntimeResumeAllProjects(options, runner, stdout)
	}

	context, _, err := loadProjectRuntimeContextForCommand(*projectKey, true)
	if err != nil {
		return err
	}
	return resumeRuntimeForContext(context, options, runner, stdout)
}

func validateRuntimeResumeOptions(options runtimeResumeOptions) error {
	sleepDuration, err := time.ParseDuration(options.Interval)
	if err != nil {
		return fmt.Errorf("parse --interval: %w", err)
	}
	if sleepDuration < 0 {
		return errors.New("--interval must be >= 0")
	}
	if strings.TrimSpace(options.MaxSteps) != "" {
		if _, err := parsePositiveInt(options.MaxSteps, "max steps"); err != nil {
			return err
		}
	}
	if strings.TrimSpace(options.AgentAttempts) != "" {
		if _, err := parsePositiveInt(options.AgentAttempts, "agent attempts"); err != nil {
			return err
		}
	}
	if _, err := parseNonNegativeDuration(options.AgentPollInterval, "agent poll interval"); err != nil {
		return err
	}
	if _, err := parseOptionalPositiveDuration(options.AgentControlPlaneConnectTimeout, "agent control plane connect timeout"); err != nil {
		return err
	}
	if _, err := parseOptionalPositiveDuration(options.AgentControlPlaneRequestTimeout, "agent control plane request timeout"); err != nil {
		return err
	}
	if strings.TrimSpace(options.AgentControlPlaneRetries) != "" {
		if _, err := parseNonNegativeInt(options.AgentControlPlaneRetries, "agent control plane retries"); err != nil {
			return err
		}
	}
	if _, err := parseNonNegativeDuration(options.AgentControlPlaneRetryDelay, "agent control plane retry delay"); err != nil {
		return err
	}
	return nil
}

func runRuntimeResumeAllProjects(options runtimeResumeOptions, runner commandRunner, stdout io.Writer) error {
	registryPath, registry, err := loadProjectRegistryFromWorkingTree("--all-projects")
	if err != nil {
		return err
	}
	if err := validateAllProjectLifecycleSurfaces(registryPath, registry); err != nil {
		return err
	}
	failures := 0
	for _, key := range sortedProjectKeys(registry) {
		context, err := projectRuntimeContextFromRegistry(registryPath, registry, key)
		if err != nil {
			failures++
			fmt.Fprintf(stdout, "project_key=%s runtime_resume_error=%s\n", key, singleLine(err.Error()))
			continue
		}
		var projectOutput bytes.Buffer
		if err := resumeRuntimeForContext(context, options, runner, &projectOutput); err != nil {
			failures++
			fmt.Fprintf(stdout, "project_key=%s runtime_resume_error=%s\n", context.ProjectKey, singleLine(err.Error()))
			continue
		}
		for _, line := range strings.Split(strings.TrimRight(projectOutput.String(), "\n"), "\n") {
			if strings.TrimSpace(line) == "" {
				continue
			}
			fmt.Fprintf(stdout, "project_key=%s %s\n", context.ProjectKey, line)
		}
	}
	if failures > 0 {
		return fmt.Errorf("runtime resume --all-projects failed for %d project(s)", failures)
	}
	return nil
}

func resumeRuntimeForContext(context *projectRuntimeContext, options runtimeResumeOptions, runner commandRunner, stdout io.Writer) error {
	effectiveConfig := applyAgentInstallOverrides(context.Config, "", "", "")
	if _, err := buildRuntimeRunOncePlan(effectiveConfig, runtimeRunOnceOverrides{
		MaxSteps:                        options.MaxSteps,
		AgentAttempts:                   options.AgentAttempts,
		AgentPollInterval:               options.AgentPollInterval,
		AgentControlPlaneConnectTimeout: options.AgentControlPlaneConnectTimeout,
		AgentControlPlaneRequestTimeout: options.AgentControlPlaneRequestTimeout,
		AgentControlPlaneRetries:        options.AgentControlPlaneRetries,
		AgentControlPlaneRetryDelay:     options.AgentControlPlaneRetryDelay,
	}, ""); err != nil {
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
		fmt.Fprintf(stdout, "describe_task=a2o runtime describe-task%s <task-ref>\n", runtimeProjectCommandArg(context.ProjectKey, effectiveConfig.MultiProjectMode))
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
	loopArgs := []string{"runtime", "loop", "--interval", options.Interval}
	if effectiveConfig.MultiProjectMode && context.ProjectKey != "" {
		loopArgs = append(loopArgs, "--project", context.ProjectKey)
	}
	loopArgs = append(loopArgs, buildRunOnceArgs(runtimeRunOnceOverrides{
		MaxSteps:                        options.MaxSteps,
		AgentAttempts:                   options.AgentAttempts,
		AgentPollInterval:               options.AgentPollInterval,
		AgentControlPlaneConnectTimeout: options.AgentControlPlaneConnectTimeout,
		AgentControlPlaneRequestTimeout: options.AgentControlPlaneRequestTimeout,
		AgentControlPlaneRetries:        options.AgentControlPlaneRetries,
		AgentControlPlaneRetryDelay:     options.AgentControlPlaneRetryDelay,
	})...)
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
	fmt.Fprintf(stdout, "describe_task=a2o runtime describe-task%s <task-ref>\n", runtimeProjectCommandArg(context.ProjectKey, effectiveConfig.MultiProjectMode))
	return nil
}

func runRuntimePause(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime pause", flag.ContinueOnError)
	flags.SetOutput(stderr)
	projectKey := flags.String("project", "", "runtime project key")
	allProjects := flags.Bool("all-projects", false, "pause schedulers for every project in the runtime project registry")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	if *allProjects && strings.TrimSpace(*projectKey) != "" {
		return fmt.Errorf("--all-projects cannot be combined with --project")
	}
	if *allProjects {
		return runRuntimePauseAllProjects(runner, stdout)
	}

	context, _, err := loadProjectRuntimeContextForCommand(*projectKey, true)
	if err != nil {
		return err
	}
	return pauseRuntimeForContext(context, runner, stdout)
}

func runRuntimePauseAllProjects(runner commandRunner, stdout io.Writer) error {
	registryPath, registry, err := loadProjectRegistryFromWorkingTree("--all-projects")
	if err != nil {
		return err
	}
	if err := validateAllProjectLifecycleSurfaces(registryPath, registry); err != nil {
		return err
	}
	failures := 0
	for _, key := range sortedProjectKeys(registry) {
		context, err := projectRuntimeContextFromRegistry(registryPath, registry, key)
		if err != nil {
			failures++
			fmt.Fprintf(stdout, "project_key=%s runtime_pause_error=%s\n", key, singleLine(err.Error()))
			continue
		}
		var projectOutput bytes.Buffer
		if err := pauseRuntimeForContext(context, runner, &projectOutput); err != nil {
			failures++
			fmt.Fprintf(stdout, "project_key=%s runtime_pause_error=%s\n", context.ProjectKey, singleLine(err.Error()))
			continue
		}
		for _, line := range strings.Split(strings.TrimRight(projectOutput.String(), "\n"), "\n") {
			if strings.TrimSpace(line) == "" {
				continue
			}
			fmt.Fprintf(stdout, "project_key=%s %s\n", context.ProjectKey, line)
		}
	}
	if failures > 0 {
		return fmt.Errorf("runtime pause --all-projects failed for %d project(s)", failures)
	}
	return nil
}

func pauseRuntimeForContext(context *projectRuntimeContext, runner commandRunner, stdout io.Writer) error {
	effectiveConfig := applyAgentInstallOverrides(context.Config, "", "", "")
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

func runRuntimeImageDigest(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime image-digest", flag.ContinueOnError)
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
		{name: "kanban_service", service: "kanbalone"},
	} {
		if check.name == "kanban_service" && isExternalKanban(config) {
			if err := checkExternalKanbanHealth(kanbanPublicURL(config)); err != nil {
				fmt.Fprintf(stdout, "runtime_status_check name=kanban_external status=blocked detail=%s\n", singleLine(err.Error()))
				continue
			}
			fmt.Fprintf(stdout, "runtime_status_check name=kanban_external status=ok url=%s runtime_url=%s\n", kanbanPublicURL(config), kanbanRuntimeURL(config))
			continue
		}
		output, err := runExternal(runner, "docker", append(composeArgs(config), "ps", "--status", "running", "-q", check.service)...)
		if err != nil {
			fmt.Fprintf(stdout, "runtime_status_check name=%s status=blocked detail=%s\n", check.name, singleLine(err.Error()))
			continue
		}
		containerID := strings.TrimSpace(string(output))
		if containerID == "" {
			fmt.Fprintf(stdout, "runtime_status_check name=%s status=stopped action=run a2o runtime up%s\n", check.name, runtimeProjectCommandArg(config.ProjectKey, config.MultiProjectMode))
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
	ConfiguredRef      string
	ConfiguredDigest   string
	ConfiguredImageID  string
	LocalLatestRef     string
	LocalLatestDigest  string
	LocalLatestImageID string
	RunningContainer   string
	RunningImageID     string
	RunningDigest      string
	ProjectKey         string
	MultiProjectMode   bool
}

func runtimeImageDigestReport(config *runtimeInstanceConfig, runner commandRunner) runtimeImageReport {
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	configuredRef := runtimeImageReference(config)
	configuredIdentity := runtimeImageIdentity(&effectiveConfig, runner)
	report := runtimeImageReport{
		ConfiguredRef:     configuredRef,
		ConfiguredDigest:  configuredIdentity.Digest,
		ConfiguredImageID: configuredIdentity.ImageID,
		LocalLatestRef:    latestRuntimeImageReference(configuredRef),
		ProjectKey:        effectiveConfig.ProjectKey,
		MultiProjectMode:  effectiveConfig.MultiProjectMode,
	}
	if report.LocalLatestRef != "" {
		report.LocalLatestDigest = imageDigestForReference(report.LocalLatestRef, runner)
		report.LocalLatestImageID = imageIDForReference(report.LocalLatestRef, runner)
	}
	report.RunningContainer, report.RunningImageID, report.RunningDigest = runningRuntimeImageDigest(effectiveConfig, runner)
	return report
}

func printRuntimeImageDigestReport(report runtimeImageReport, stdout io.Writer) {
	fmt.Fprintf(stdout, "runtime_image_digest=%s\n", valueOrUnavailable(report.ConfiguredDigest))
	fmt.Fprintf(stdout, "runtime_image_pinned_ref=%s\n", valueOrUnavailable(report.ConfiguredRef))
	fmt.Fprintf(stdout, "runtime_image_pinned_digest=%s\n", valueOrUnavailable(report.ConfiguredDigest))
	fmt.Fprintf(stdout, "runtime_image_pinned_image_id=%s\n", valueOrUnavailable(report.ConfiguredImageID))
	fmt.Fprintf(stdout, "runtime_image_local_latest_ref=%s\n", valueOrUnavailable(report.LocalLatestRef))
	fmt.Fprintf(stdout, "runtime_image_local_latest_digest=%s\n", valueOrUnavailable(report.LocalLatestDigest))
	fmt.Fprintf(stdout, "runtime_image_local_latest_image_id=%s\n", valueOrUnavailable(report.LocalLatestImageID))
	if report.RunningContainer == "" {
		fmt.Fprintln(stdout, "runtime_image_running_container=unavailable")
	} else {
		fmt.Fprintf(stdout, "runtime_image_running_container=%s image_id=%s digest=%s\n", report.RunningContainer, valueOrUnavailable(report.RunningImageID), valueOrUnavailable(report.RunningDigest))
	}
	latestStatus := runtimeImageComparisonStatus(report.ConfiguredDigest, report.LocalLatestDigest, report.ConfiguredImageID, report.LocalLatestImageID)
	runningStatus := runtimeImageComparisonStatus(report.ConfiguredDigest, report.RunningDigest, report.ConfiguredImageID, report.RunningImageID)
	fmt.Fprintf(stdout, "runtime_image_latest_status=%s action=%s\n", latestStatus, runtimeImageLatestAction(latestStatus, report.LocalLatestRef, report))
	fmt.Fprintf(stdout, "runtime_image_running_status=%s action=%s\n", runningStatus, runtimeImageRunningAction(runningStatus, report))
}

func runtimeImageComparisonStatus(expected string, actual string, expectedImageID string, actualImageID string) string {
	expectedDigest := digestIdentity(expected)
	actualDigest := digestIdentity(actual)
	if expectedDigest != "" && actualDigest != "" {
		if expectedDigest == actualDigest {
			return "current"
		}
		return "mismatch"
	}
	expectedID := imageIDIdentity(expectedImageID)
	actualID := imageIDIdentity(actualImageID)
	if expectedDigest == "" && actualDigest == "" && expectedID != "" && actualID != "" {
		if expectedID == actualID {
			return "current"
		}
		return "mismatch"
	}
	return "unknown"
}

func imageIDIdentity(imageID string) string {
	return strings.TrimPrefix(strings.TrimSpace(imageID), "sha256:")
}

func runtimeImageLatestAction(status string, latestRef string, report runtimeImageReport) string {
	imageDigestCommand := "a2o runtime image-digest" + runtimeProjectCommandArg(report.ProjectKey, report.MultiProjectMode)
	switch status {
	case "current":
		return "none"
	case "mismatch":
		return "validate local latest, then update the package runtime image pin if you want this version"
	default:
		if latestRef == "" {
			return "configure A2O_RUNTIME_IMAGE, pull or inspect the configured runtime image, then rerun " + imageDigestCommand
		}
		return "pull " + latestRef + " or inspect the configured runtime image, then rerun " + imageDigestCommand
	}
}

func runtimeImageRunningAction(status string, report runtimeImageReport) string {
	runtimeUpCommand := "a2o runtime up" + runtimeProjectCommandArg(report.ProjectKey, report.MultiProjectMode)
	runtimeStatusCommand := "a2o runtime status" + runtimeProjectCommandArg(report.ProjectKey, report.MultiProjectMode)
	switch status {
	case "current":
		return "none"
	case "mismatch":
		return "restart runtime with " + runtimeUpCommand + " after confirming the desired pinned digest"
	default:
		return "run " + runtimeUpCommand + ", then rerun " + runtimeStatusCommand
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

func runRuntimeResetTask(args []string, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime reset-task", flag.ContinueOnError)
	flags.SetOutput(stderr)
	projectKey := flags.String("project", "", "runtime project key")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 1 {
		return fmt.Errorf("usage: a2o runtime reset-task [--project KEY] TASK_REF")
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
	plan, err := buildRuntimeRunOncePlan(effectiveConfig, runtimeRunOnceOverrides{}, "")
	if err != nil {
		return err
	}

	fmt.Fprintf(stdout, "reset_task_plan task_ref=%s mode=dry-run\n", taskRef)
	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", publicInstanceConfigPath(configPath))
	fmt.Fprintf(stdout, "runtime_project_key=%s\n", context.ProjectKey)
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
	projectArg := runtimeProjectCommandArg(context.ProjectKey, effectiveConfig.MultiProjectMode)
	fmt.Fprintf(stdout, "recovery_step 1 command=a2o runtime describe-task%s %s purpose=read blocked reason, run, evidence, kanban comments, and logs\n", projectArg, taskRef)
	fmt.Fprintf(stdout, "recovery_step 2 command=a2o runtime watch-summary%s purpose=confirm the scheduler sees the task as blocked and no sibling task is still running\n", projectArg)
	fmt.Fprintln(stdout, "recovery_step 3 action=fix_root_cause purpose=repair executor config, dirty repo, missing command, merge conflict, or product failure reported by describe-task")
	fmt.Fprintln(stdout, "recovery_step 4 action=preserve_manual_changes purpose=commit, patch, or discard any useful changes in the listed workspace and branches")
	fmt.Fprintln(stdout, "recovery_step 5 action=clear_blocked_label purpose=remove the kanban blocked label only after the root cause is fixed")
	fmt.Fprintf(stdout, "recovery_step 6 command=a2o runtime run-once%s purpose=let A2O resync kanban state and start a fresh run\n", projectArg)
	fmt.Fprintln(stdout, "apply_supported=false")
	return nil
}

func runtimeProjectCommandArg(projectKey string, multiProjectMode bool) string {
	trimmed := strings.TrimSpace(projectKey)
	if !multiProjectMode || trimmed == "" {
		return ""
	}
	return " --project " + trimmed
}

func runRuntimeForceStop(kind string, args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	commandName := "force-stop-" + kind
	flags := flag.NewFlagSet("a2o runtime "+commandName, flag.ContinueOnError)
	flags.SetOutput(stderr)
	dangerous := flags.Bool("dangerous", false, "confirm intentional destructive intervention")
	outcome := flags.String("outcome", "cancelled", "terminal outcome to write for the force-stopped run")
	projectKey := flags.String("project", "", "runtime project key")
	flagArgs, positionals, err := splitRuntimeForceStopArgs(args)
	if err != nil {
		return err
	}
	if err := flags.Parse(flagArgs); err != nil {
		return err
	}
	if !*dangerous {
		return fmt.Errorf("usage: a2o runtime %s <%s-ref> --dangerous", commandName, kind)
	}
	if len(positionals) != 1 {
		return fmt.Errorf("usage: a2o runtime %s <%s-ref> --dangerous", commandName, kind)
	}
	targetRef := strings.TrimSpace(positionals[0])
	if targetRef == "" {
		return fmt.Errorf("%s ref is required", kind)
	}
	resolvedProject := strings.TrimSpace(*projectKey)
	if kind == "task" {
		var err error
		resolvedProject, targetRef, err = resolveRuntimeProjectTaskRef(*projectKey, targetRef)
		if err != nil {
			return err
		}
	}

	context, configPath, err := loadProjectRuntimeContextForCommand(resolvedProject, true)
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(context.Config, "", "", "")
	return withComposeEnv(effectiveConfig, func() error {
		plan, err := buildRuntimeRunOncePlan(effectiveConfig, runtimeRunOnceOverrides{}, "")
		if err != nil {
			return err
		}
		fmt.Fprintf(stdout, "runtime_force_stop target=%s ref=%s mode=dangerous\n", kind, targetRef)
		fmt.Fprintf(stdout, "runtime_instance_config=%s\n", publicInstanceConfigPath(configPath))
		fmt.Fprintf(stdout, "runtime_project_key=%s\n", context.ProjectKey)
		fmt.Fprintf(stdout, "runtime_storage=internal-managed project_config=%s surface_source=project-package\n", plan.ManifestPath)
		output, err := dockerComposeExecOutput(
			effectiveConfig,
			plan,
			runner,
			"a3",
			commandName,
			"--storage-backend",
			"json",
			"--storage-dir",
			plan.StorageDir,
			"--outcome",
			*outcome,
			"--dangerous",
			targetRef,
		)
		if strings.TrimSpace(string(output)) != "" {
			fmt.Fprint(stdout, string(output))
			if !strings.HasSuffix(string(output), "\n") {
				fmt.Fprintln(stdout)
			}
		}
		if err != nil {
			return fmt.Errorf("runtime %s: %w", commandName, err)
		}
		stopRuntimeActiveProcesses(effectiveConfig, plan, runner)
		fmt.Fprintln(stdout, "runtime_force_stop_process_cleanup=best_effort")
		return nil
	})
}

func splitRuntimeForceStopArgs(args []string) ([]string, []string, error) {
	flagArgs := []string{}
	positionals := []string{}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "--dangerous":
			flagArgs = append(flagArgs, arg)
		case arg == "--outcome":
			if i+1 >= len(args) {
				return nil, nil, fmt.Errorf("flag needs an argument: --outcome")
			}
			flagArgs = append(flagArgs, arg, args[i+1])
			i++
		case strings.HasPrefix(arg, "--outcome="):
			flagArgs = append(flagArgs, arg)
		case arg == "--project":
			if i+1 >= len(args) {
				return nil, nil, fmt.Errorf("flag needs an argument: --project")
			}
			flagArgs = append(flagArgs, arg, args[i+1])
			i++
		case strings.HasPrefix(arg, "--project="):
			flagArgs = append(flagArgs, arg)
		case strings.HasPrefix(arg, "-"):
			flagArgs = append(flagArgs, arg)
		default:
			positionals = append(positionals, arg)
		}
	}
	return flagArgs, positionals, nil
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

func runRuntimeLogs(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	normalizedArgs, err := normalizeRuntimeLogsArgs(args)
	if err != nil {
		return err
	}
	flags := flag.NewFlagSet("a2o runtime logs", flag.ContinueOnError)
	flags.SetOutput(stderr)
	follow := flags.Bool("follow", false, "follow the current phase live log while the task is running")
	flags.BoolVar(follow, "f", false, "follow the current phase live log while the task is running")
	index := flags.Int("index", -1, "select a running task by index when --follow has multiple candidates")
	flags.IntVar(index, "i", -1, "select a running task by index when --follow has multiple candidates")
	noChildren := flags.Bool("no-children", false, "when following a parent task, follow the parent itself instead of active children")
	pollInterval := flags.Duration("poll-interval", time.Second, "poll interval for --follow")
	projectKey := flags.String("project", "", "runtime project key")
	if err := flags.Parse(normalizedArgs); err != nil {
		return err
	}
	if flags.NArg() > 1 || (flags.NArg() == 0 && !*follow) {
		return fmt.Errorf("usage: a2o runtime logs [TASK_REF] [--follow] [--index N] [--no-children]")
	}
	taskRef := ""
	if flags.NArg() == 1 {
		taskRef = strings.TrimSpace(flags.Arg(0))
		if taskRef == "" {
			return fmt.Errorf("task ref is required")
		}
	}
	resolvedProject := strings.TrimSpace(*projectKey)
	if taskRef != "" {
		var err error
		resolvedProject, taskRef, err = resolveRuntimeProjectTaskRef(*projectKey, taskRef)
		if err != nil {
			return err
		}
	}

	context, _, err := loadProjectRuntimeContextForCommand(resolvedProject, taskRef != "" || *follow)
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(context.Config, "", "", "")
	return withComposeEnv(effectiveConfig, func() error {
		plan, err := buildRuntimeDescribeTaskPlan(effectiveConfig)
		if err != nil {
			return err
		}
		requestedTaskRef := taskRef
		dynamicFollow := false
		if *follow {
			resolvedTarget, err := resolveRuntimeLogsFollowTarget(effectiveConfig, plan, runner, stderr, requestedTaskRef, *index, *noChildren)
			if err != nil {
				return err
			}
			taskRef = resolvedTarget.TaskRef
			dynamicFollow = resolvedTarget.Dynamic
		} else if err := validateRuntimeLogsTaskRef(effectiveConfig, plan, runner, taskRef); err != nil {
			return err
		}
		printedArtifacts := map[string]bool{}
		offsets := map[string]int64{}
		lastLiveKey := ""
		lastWaitingKey := ""
		for {
			var manifest runtimeTaskLogSnapshot
			var err error
			if *follow {
				manifest, err = runtimeTaskLogManifest(effectiveConfig, plan, runner, taskRef)
			} else {
				manifest, err = runtimeStaticTaskLogManifest(effectiveConfig, plan, runner, taskRef, !*noChildren)
			}
			if err != nil {
				return err
			}
			for _, item := range manifest.CompletedArtifacts {
				if printedArtifacts[item.ArtifactID] {
					continue
				}
				headerTaskRef := ""
				if !*follow && strings.TrimSpace(item.TaskRef) != "" && item.TaskRef != taskRef {
					headerTaskRef = item.TaskRef
				}
				if err := printRuntimeArtifactSection(effectiveConfig, plan, runner, stdout, headerTaskRef, item.Phase, item.ArtifactID, item.Mode); err != nil {
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
			if !*follow {
				return nil
			}
			if !manifest.Active || manifest.CurrentRunRef == "" || manifest.CurrentPhase == "" {
				if !runtimeLogsShouldKeepFollowing(manifest.TaskStatus) {
					if dynamicFollow {
						resolvedTarget, err := resolveRuntimeLogsFollowTarget(effectiveConfig, plan, runner, stderr, requestedTaskRef, -1, *noChildren)
						if err != nil {
							if strings.TrimSpace(requestedTaskRef) == "" && strings.Contains(err.Error(), "no running task found for --follow") {
								return nil
							}
							return err
						}
						nextTaskRef := strings.TrimSpace(resolvedTarget.TaskRef)
						if nextTaskRef != "" && nextTaskRef != taskRef {
							fmt.Fprintf(stdout, "=== switching: task=%s -> task=%s ===\n", taskRef, nextTaskRef)
							taskRef = nextTaskRef
							lastLiveKey = ""
							lastWaitingKey = ""
							continue
						}
					}
					return nil
				}
				waitingKey := manifest.TaskStatus + "|" + manifest.CurrentRunRef + "|" + manifest.CurrentPhase
				if waitingKey != lastWaitingKey {
					fmt.Fprintf(stdout, "=== waiting: task=%s status=%s next phase/run ===\n", taskRef, valueOrUnavailable(manifest.TaskStatus))
					lastWaitingKey = waitingKey
				}
			}
			time.Sleep(*pollInterval)
		}
	})
}

func validateRuntimeLogsTaskRef(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, taskRef string) error {
	_, err := runtimeDescribeSectionOutput(config, plan, runner, "task", "a3", "show-task", "--storage-backend", "json", "--storage-dir", plan.StorageDir, taskRef)
	return err
}

func normalizeRuntimeLogsArgs(args []string) ([]string, error) {
	normalized := make([]string, 0, len(args))
	taskRef := ""
	for index := 0; index < len(args); index++ {
		arg := args[index]
		switch {
		case arg == "--follow" || arg == "-f":
			normalized = append(normalized, arg)
		case arg == "--poll-interval":
			if index+1 >= len(args) {
				return nil, fmt.Errorf("flag needs an argument: --poll-interval")
			}
			normalized = append(normalized, arg, args[index+1])
			index++
		case strings.HasPrefix(arg, "--poll-interval="):
			normalized = append(normalized, arg)
		case arg == "--project":
			if index+1 >= len(args) {
				return nil, fmt.Errorf("flag needs an argument: --project")
			}
			normalized = append(normalized, arg, args[index+1])
			index++
		case strings.HasPrefix(arg, "--project="):
			normalized = append(normalized, arg)
		case arg == "--index" || arg == "-i":
			if index+1 >= len(args) {
				return nil, fmt.Errorf("flag needs an argument: %s", arg)
			}
			normalized = append(normalized, arg, args[index+1])
			index++
		case strings.HasPrefix(arg, "--index=") || strings.HasPrefix(arg, "-i="):
			normalized = append(normalized, arg)
		case arg == "--no-children":
			normalized = append(normalized, arg)
		case strings.HasPrefix(arg, "-"):
			normalized = append(normalized, arg)
		default:
			if taskRef != "" {
				return nil, fmt.Errorf("usage: a2o runtime logs [TASK_REF] [--follow] [--index N] [--no-children]")
			}
			taskRef = arg
		}
	}
	if taskRef != "" {
		normalized = append(normalized, taskRef)
	}
	return normalized, nil
}

type runtimeLogFollowTarget struct {
	TaskRef   string `json:"task_ref"`
	RunRef    string `json:"run_ref"`
	Phase     string `json:"phase"`
	Kind      string `json:"kind"`
	ParentRef string `json:"parent_ref"`
}

type runtimeLogFollowTargetPayload struct {
	RequestedTaskRef string                   `json:"requested_task_ref"`
	SelectedTaskRef  string                   `json:"selected_task_ref"`
	DynamicFollow    bool                     `json:"dynamic_follow"`
	Candidates       []runtimeLogFollowTarget `json:"candidates"`
}

type resolvedRuntimeLogsFollowTarget struct {
	TaskRef string
	Dynamic bool
}

func resolveRuntimeLogsFollowTaskRef(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stderr io.Writer, requestedTaskRef string, index int, noChildren bool) (string, error) {
	target, err := resolveRuntimeLogsFollowTarget(config, plan, runner, stderr, requestedTaskRef, index, noChildren)
	if err != nil {
		return "", err
	}
	return target.TaskRef, nil
}

func resolveRuntimeLogsFollowTarget(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stderr io.Writer, requestedTaskRef string, index int, noChildren bool) (resolvedRuntimeLogsFollowTarget, error) {
	payload, err := runtimeLogsFollowTargets(config, plan, runner, requestedTaskRef, noChildren)
	if err != nil {
		return resolvedRuntimeLogsFollowTarget{}, err
	}
	selected := strings.TrimSpace(payload.SelectedTaskRef)
	if index >= 0 {
		if len(payload.Candidates) == 0 && selected != "" {
			return resolvedRuntimeLogsFollowTarget{TaskRef: selected, Dynamic: payload.DynamicFollow}, nil
		}
		if index >= len(payload.Candidates) {
			printRuntimeLogsFollowCandidates(stderr, payload.Candidates)
			return resolvedRuntimeLogsFollowTarget{}, fmt.Errorf("--index %d is out of range for %d running task(s)", index, len(payload.Candidates))
		}
		selected := strings.TrimSpace(payload.Candidates[index].TaskRef)
		if selected == "" {
			return resolvedRuntimeLogsFollowTarget{}, fmt.Errorf("selected running task has empty task ref")
		}
		return resolvedRuntimeLogsFollowTarget{TaskRef: selected, Dynamic: payload.DynamicFollow}, nil
	}
	if selected != "" {
		return resolvedRuntimeLogsFollowTarget{TaskRef: selected, Dynamic: payload.DynamicFollow}, nil
	}
	if len(payload.Candidates) == 1 {
		selected = strings.TrimSpace(payload.Candidates[0].TaskRef)
		if selected != "" {
			return resolvedRuntimeLogsFollowTarget{TaskRef: selected, Dynamic: payload.DynamicFollow}, nil
		}
	}
	if len(payload.Candidates) > 1 {
		printRuntimeLogsFollowCandidates(stderr, payload.Candidates)
		return resolvedRuntimeLogsFollowTarget{}, fmt.Errorf("multiple running tasks match; pass --index N to select one")
	}
	if strings.TrimSpace(requestedTaskRef) != "" {
		return resolvedRuntimeLogsFollowTarget{TaskRef: strings.TrimSpace(requestedTaskRef), Dynamic: payload.DynamicFollow}, nil
	}
	return resolvedRuntimeLogsFollowTarget{}, fmt.Errorf("no running task found for --follow")
}

func printRuntimeLogsFollowCandidates(stderr io.Writer, candidates []runtimeLogFollowTarget) {
	if stderr == nil || len(candidates) == 0 {
		return
	}
	fmt.Fprintln(stderr, "running task candidates:")
	for index, candidate := range candidates {
		parent := ""
		if strings.TrimSpace(candidate.ParentRef) != "" {
			parent = " parent=" + candidate.ParentRef
		}
		fmt.Fprintf(stderr, "  [%d] task=%s run=%s phase=%s kind=%s%s\n", index, valueOrUnavailable(candidate.TaskRef), valueOrUnavailable(candidate.RunRef), valueOrUnavailable(candidate.Phase), valueOrUnavailable(candidate.Kind), parent)
	}
}

func runtimeLogsFollowTargets(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, requestedTaskRef string, noChildren bool) (runtimeLogFollowTargetPayload, error) {
	script := strings.Join([]string{
		"tasks_path = ARGV.fetch(0)",
		"runs_path = ARGV.fetch(1)",
		"requested = ARGV.fetch(2).to_s",
		"no_children = ARGV.fetch(3) == 'true'",
		"tasks = File.exist?(tasks_path) ? JSON.parse(File.read(tasks_path)) : {}",
		"runs = File.exist?(runs_path) ? JSON.parse(File.read(runs_path)) : {}",
		"active_runs = runs.values.select do |record|",
		"  task_ref = record['task_ref'].to_s",
		"  task = tasks[task_ref]",
		"  task_ref != '' && task && task['current_run_ref'].to_s == record['ref'].to_s && record['terminal_outcome'].nil?",
		"end",
		"targets = active_runs.map do |run|",
		"  task_ref = run['task_ref'].to_s",
		"  task = tasks[task_ref] || {}",
		"  {'task_ref' => task_ref, 'run_ref' => run['ref'].to_s, 'phase' => run['phase'].to_s, 'kind' => task['kind'].to_s, 'parent_ref' => task['parent_ref'].to_s}",
		"end.sort_by { |item| [item['task_ref'], item['run_ref']] }",
		"selected = ''",
		"candidates = []",
		"dynamic_follow = false",
		"if requested.empty?",
		"  candidates = targets",
		"  dynamic_follow = true",
		"elsif (task = tasks[requested]) && task['kind'].to_s == 'parent' && !no_children",
		"  child_refs = Array(task['child_refs']).map(&:to_s)",
		"  candidates = targets.select { |item| child_refs.include?(item['task_ref']) || item['parent_ref'] == requested }",
		"  selected = requested if candidates.empty?",
		"  dynamic_follow = true",
		"else",
		"  selected = requested",
		"end",
		"puts JSON.generate({'requested_task_ref' => requested, 'selected_task_ref' => selected, 'dynamic_follow' => dynamic_follow, 'candidates' => candidates})",
	}, "; ")
	output, err := dockerComposeExecOutput(config, plan, runner, "ruby", "-rjson", "-e", script, path.Join(plan.StorageDir, "tasks.json"), path.Join(plan.StorageDir, "runs.json"), requestedTaskRef, fmt.Sprintf("%t", noChildren))
	if err != nil {
		return runtimeLogFollowTargetPayload{}, err
	}
	var payload runtimeLogFollowTargetPayload
	if err := json.Unmarshal(output, &payload); err != nil {
		return runtimeLogFollowTargetPayload{}, err
	}
	return payload, nil
}

func runRuntimeShowArtifact(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o runtime show-artifact", flag.ContinueOnError)
	flags.SetOutput(stderr)
	projectKey := flags.String("project", "", "runtime project key")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 1 {
		return fmt.Errorf("usage: a2o runtime show-artifact [--project KEY] ARTIFACT_ID")
	}
	artifactID := strings.TrimSpace(flags.Arg(0))
	if artifactID == "" {
		return fmt.Errorf("artifact id is required")
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
	projectKey := flags.String("project", "", "runtime project key")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *taskRef == "" && *runRef == "" && !*allAnalysis {
		return fmt.Errorf("usage: a2o runtime clear-logs (--task-ref TASK_REF | --run-ref RUN_REF | --all-analysis) [--phase PHASE] [--role ROLE] [--apply]")
	}
	resolvedProject := strings.TrimSpace(*projectKey)
	if *taskRef != "" {
		var err error
		resolvedProject, *taskRef, err = resolveRuntimeProjectTaskRef(*projectKey, *taskRef)
		if err != nil {
			return err
		}
	}

	context, _, err := loadProjectRuntimeContextForCommand(resolvedProject, true)
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(context.Config, "", "", "")
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
	ProjectKey                      string
	MultiProjectMode                bool
	ComposePrefix                   []string
	MaxSteps                        string
	AgentAttempts                   int
	AgentIdleLimit                  int
	AgentPollInterval               time.Duration
	AgentControlPlaneConnectTimeout time.Duration
	AgentControlPlaneRequestTimeout time.Duration
	AgentControlPlaneRetryCount     int
	AgentControlPlaneRetryDelay     time.Duration
	AgentPort                       string
	AgentInternalPort               string
	StorageDir                      string
	HostRootDir                     string
	HostRoot                        string
	WorkspaceRoot                   string
	HostAgentBin                    string
	HostAgentSource                 string
	HostAgentTarget                 string
	HostAgentLog                    string
	LiveLogRoot                     string
	AIRawLogRoot                    string
	LauncherConfigPath              string
	LauncherConfig                  map[string]any
	ServerLog                       string
	RuntimeLog                      string
	RuntimeExitFile                 string
	RuntimePIDFile                  string
	ServerPIDFile                   string
	PresetDir                       string
	ManifestPath                    string
	SoloBoardInternalURL            string
	LiveRef                         string
	AgentEnv                        []string
	AgentSourcePaths                []string
	AgentRequiredBins               []string
	AgentSourceAliases              []string
	KanbanProject                   string
	KanbanStatus                    string
	KanbanRepoLabels                []string
	RepoSources                     []string
	LocalSourceAliases              []string
	WorkerCommand                   string
	WorkerArgs                      []string
	JobTimeoutSeconds               string
	BranchNamespace                 string
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
		fmt.Fprintf(stdout, "kanban_run_once=generic\n")
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
		requiredBins = []string{"git", "node"}
	}
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
			"A3_MAVEN_WORKSPACE_BOOTSTRAP_MODE=" + envDefaultCompat("A2O_RUNTIME_RUN_ONCE_MAVEN_WORKSPACE_BOOTSTRAP_MODE", "A3_RUNTIME_RUN_ONCE_MAVEN_WORKSPACE_BOOTSTRAP_MODE", envDefaultCompat("A2O_RUNTIME_SCHEDULER_MAVEN_WORKSPACE_BOOTSTRAP_MODE", "A3_RUNTIME_SCHEDULER_MAVEN_WORKSPACE_BOOTSTRAP_MODE", "empty")),
		}, projectAgentEnv(projectKey, config.MultiProjectMode)...),
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
		BranchNamespace:    defaultProjectBranchNamespace(config),
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

type runtimePhaseLogArtifact struct {
	TaskRef    string `json:"task_ref"`
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
	TaskStatus string                    `json:"task_status"`
	Active     bool                      `json:"active"`
	Artifacts  []runtimePhaseLogArtifact `json:"artifacts"`
}

type runtimeTaskLogSnapshot struct {
	RunRef             string
	CurrentRunRef      string
	CurrentPhase       string
	SourceType         string
	SourceRef          string
	TaskStatus         string
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
	taskStatus := parseOutputValue(taskOutput, "status")
	script := strings.Join([]string{
		"records = JSON.parse(File.read(ARGV.fetch(0)))",
		"task_ref = ARGV.fetch(1)",
		"current_run = ARGV.fetch(2)",
		"task_status = ARGV.fetch(3)",
		"task_runs = records.values.select { |record| record['task_ref'] == task_ref }",
		"run = records[current_run] unless current_run.empty?",
		"run = nil unless run.nil? || run['task_ref'] == task_ref",
		"run ||= task_runs.last",
		"effective_current_run = current_run",
		"if run.nil? then puts JSON.generate({'run_ref' => '', 'current_run' => effective_current_run, 'phase' => '', 'source_type' => '', 'source_ref' => '', 'task_status' => task_status, 'active' => false, 'artifacts' => []}); exit 0 end",
		"effective_current_run = run['ref'].to_s if effective_current_run.empty? || effective_current_run != run['ref'].to_s",
		"phase_records = task_runs.flat_map { |record| Array(record.dig('evidence', 'phase_records')) }",
		"artifacts = phase_records.each_with_object([]) do |phase_record, result|",
		"  entries = Array(phase_record.dig('execution_record', 'diagnostics', 'agent_artifacts'))",
		"  [['ai-raw-log', 'ai-raw-log'], ['combined-log', 'combined-log']].each do |role, mode|",
		"    artifact = entries.find { |item| item['role'] == role && item['artifact_id'].to_s != '' }",
		"    next unless artifact",
		"    result << {'phase' => phase_record['phase'].to_s, 'artifact_id' => artifact['artifact_id'].to_s, 'mode' => mode}",
		"  end",
		"end",
		"payload = {'run_ref' => run['ref'].to_s, 'current_run' => effective_current_run, 'phase' => run['phase'].to_s, 'source_type' => run.dig('source_descriptor', 'source_type').to_s, 'source_ref' => run.dig('source_descriptor', 'ref').to_s, 'task_status' => task_status, 'active' => run['terminal_outcome'].nil?, 'artifacts' => artifacts}",
		"puts JSON.generate(payload)",
	}, "; ")
	output, err := dockerComposeExecOutput(config, plan, runner, "ruby", "-rjson", "-e", script, path.Join(plan.StorageDir, "runs.json"), taskRef, currentRunRef, taskStatus)
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
		TaskStatus:         firstNonEmpty(payload.TaskStatus, taskStatus),
		Active:             payload.Active,
		LiveMode:           preferredLiveMode(plan, taskRef, payload.Phase),
		CompletedArtifacts: payload.Artifacts,
	}, nil
}

func runtimeStaticTaskLogManifest(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, taskRef string, includeChildren bool) (runtimeTaskLogSnapshot, error) {
	script := strings.Join([]string{
		"tasks_path = ARGV.fetch(0)",
		"runs_path = ARGV.fetch(1)",
		"requested = ARGV.fetch(2).to_s",
		"include_children = ARGV.fetch(3) == 'true'",
		"tasks = File.exist?(tasks_path) ? JSON.parse(File.read(tasks_path)) : {}",
		"runs = File.exist?(runs_path) ? JSON.parse(File.read(runs_path)) : {}",
		"task = tasks[requested] || {}",
		"target_refs = [requested]",
		"if include_children && task['kind'].to_s == 'parent'",
		"  child_refs = Array(task['child_refs']).map(&:to_s)",
		"  child_refs.concat(tasks.each_with_object([]) { |(ref, payload), refs| refs << ref.to_s if payload.is_a?(Hash) && payload['parent_ref'].to_s == requested })",
		"  target_refs.concat(child_refs)",
		"end",
		"target_refs = target_refs.map(&:to_s).reject(&:empty?).uniq",
		"target_set = target_refs.each_with_object({}) { |ref, memo| memo[ref] = true }",
		"seen_artifacts = {}",
		"artifacts = []",
		"runs.values.each do |record|",
		"  task_ref = record['task_ref'].to_s",
		"  next unless target_set[task_ref]",
		"  Array(record.dig('evidence', 'phase_records')).each do |phase_record|",
		"    entries = Array(phase_record.dig('execution_record', 'diagnostics', 'agent_artifacts'))",
		"    [['ai-raw-log', 'ai-raw-log'], ['combined-log', 'combined-log']].each do |role, mode|",
		"      artifact = entries.find { |item| item['role'] == role && item['artifact_id'].to_s != '' }",
		"      next unless artifact",
		"      artifact_id = artifact['artifact_id'].to_s",
		"      next if seen_artifacts[artifact_id]",
		"      seen_artifacts[artifact_id] = true",
		"      artifacts << {'task_ref' => task_ref, 'phase' => phase_record['phase'].to_s, 'artifact_id' => artifact_id, 'mode' => mode}",
		"    end",
		"  end",
		"end",
		"payload = {'run_ref' => '', 'current_run' => '', 'phase' => '', 'source_type' => '', 'source_ref' => '', 'task_status' => task['status'].to_s, 'active' => false, 'artifacts' => artifacts}",
		"puts JSON.generate(payload)",
	}, "; ")
	output, err := dockerComposeExecOutput(config, plan, runner, "ruby", "-rjson", "-e", script, path.Join(plan.StorageDir, "tasks.json"), path.Join(plan.StorageDir, "runs.json"), taskRef, fmt.Sprintf("%t", includeChildren))
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
		TaskStatus:         payload.TaskStatus,
		Active:             payload.Active,
		LiveMode:           preferredLiveMode(plan, taskRef, payload.Phase),
		CompletedArtifacts: payload.Artifacts,
	}, nil
}

func runtimeLogsShouldKeepFollowing(taskStatus string) bool {
	switch strings.ToLower(strings.TrimSpace(taskStatus)) {
	case "in_progress", "in review", "in_review", "verifying", "merging":
		return true
	default:
		return false
	}
}

func printRuntimeArtifactSection(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer, taskRef string, phase string, artifactID string, mode string) error {
	output, err := runtimeDescribeSectionOutput(config, plan, runner, "agent_artifact", "a3", "agent-artifact-read", "--storage-dir", plan.StorageDir, artifactID)
	if err != nil {
		return err
	}
	if strings.TrimSpace(taskRef) == "" {
		fmt.Fprintf(stdout, "=== phase: %s (%s) artifact=%s ===\n", phase, mode, artifactID)
	} else {
		fmt.Fprintf(stdout, "=== task: %s phase: %s (%s) artifact=%s ===\n", taskRef, phase, mode, artifactID)
	}
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

func startRuntimeDecompositionCommand(config runtimeInstanceConfig, plan runtimeRunOncePlan, command []string, action string, runner commandRunner, stdout io.Writer) error {
	fmt.Fprintf(stdout, "runtime_decomposition_start action=%s\n", action)
	env := map[string]string{
		"A2O_ROOT_DIR":   "/workspace",
		"KANBAN_BACKEND": "kanbalone",
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
		Args:        runtimeInspectionArgs(command...),
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
