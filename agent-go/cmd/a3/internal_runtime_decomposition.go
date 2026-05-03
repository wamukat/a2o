package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

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
	allDrafts := flags.Bool("all", false, "accept all draft children")
	readyDrafts := flags.Bool("ready", false, "accept draft children marked ready")
	removeDraftLabel := flags.Bool("remove-draft-label", false, "remove a2o:draft-child from accepted children")
	parentAuto := flags.Bool("parent-auto", true, "add trigger:auto-parent and accepted child repo labels to the generated parent after accepting children")
	noParentAuto := flags.Bool("no-parent-auto", false, "do not add parent automation labels after accepting children")
	var childRefs stringListFlag
	flags.Var(&childRefs, "child", "draft child ref to accept; may be repeated")
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
		ChildRefs:                 childRefs,
		AllDrafts:                 *allDrafts,
		ReadyDrafts:               *readyDrafts,
		RemoveDraftLabel:          *removeDraftLabel,
		ParentAuto:                *parentAuto && !*noParentAuto,
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
		case action == "accept-drafts" && (arg == "--all" || arg == "--ready" || arg == "--remove-draft-label" || arg == "--parent-auto" || arg == "--no-parent-auto"):
			flagArgs = append(flagArgs, arg)
		case action == "accept-drafts" && arg == "--child":
			if i+1 >= len(args) {
				return nil, nil, fmt.Errorf("%s requires a value", arg)
			}
			flagArgs = append(flagArgs, arg, args[i+1])
			i++
		case action == "accept-drafts" && strings.HasPrefix(arg, "--child="):
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
	ChildRefs                 []string
	AllDrafts                 bool
	ReadyDrafts               bool
	RemoveDraftLabel          bool
	ParentAuto                bool
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
	case "accept-drafts":
		args = append(args, "accept-decomposition-drafts", taskRef, "--storage-backend", "json", "--storage-dir", plan.StorageDir)
		args = append(args, runtimeDecompositionKanbanOptions(plan)...)
		for _, childRef := range overrides.ChildRefs {
			args = append(args, "--child", childRef)
		}
		if overrides.AllDrafts {
			args = append(args, "--all")
		}
		if overrides.ReadyDrafts {
			args = append(args, "--ready")
		}
		if overrides.RemoveDraftLabel {
			args = append(args, "--remove-draft-label")
		}
		if overrides.ParentAuto {
			args = append(args, "--parent-auto")
		} else {
			args = append(args, "--no-parent-auto")
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
	fmt.Fprintln(w, "usage: a2o runtime decomposition investigate|propose|review|create-children|accept-drafts|status|cleanup [--project KEY] TASK_REF [--project-config project-test.yaml]")
	fmt.Fprintln(w, "actions:")
	fmt.Fprintln(w, "  investigate       run the configured decomposition investigation command")
	fmt.Fprintln(w, "  propose           create proposal evidence from investigation evidence")
	fmt.Fprintln(w, "  review            review proposal evidence")
	fmt.Fprintln(w, "  create-children   create or reconcile Kanban child tickets; requires --gate")
	fmt.Fprintln(w, "  accept-drafts     accept draft child tickets and enable generated-parent automation")
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
	case "accept-drafts":
		fmt.Fprintln(w, "usage: a2o runtime decomposition accept-drafts [--project KEY] TASK_REF [--project-config project-test.yaml] (--child CHILD_REF...|--ready|--all) [--remove-draft-label] [--parent-auto|--no-parent-auto]")
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
func printRuntimeDecompositionLogFallback(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer, taskRef string, follow bool, pollInterval time.Duration) (bool, error) {
	taskOutput, err := runtimeDescribeSectionOutput(config, plan, runner, "task", "a3", "show-task", "--storage-backend", "json", "--storage-dir", plan.StorageDir, taskRef)
	if err != nil {
		return false, err
	}
	statusOutput, err := runtimeDescribeSectionOutput(config, plan, runner, "decomposition_status", "a3", "show-decomposition-status", "--storage-backend", "json", "--storage-dir", plan.StorageDir, taskRef)
	if err != nil {
		return false, err
	}
	state := parseOutputValue(statusOutput, "state")
	isDecompositionSource := parseOutputValue(taskOutput, "runnable_reason") == "decomposition_requested"
	if !isDecompositionSource && state == "none" {
		return false, nil
	}

	fmt.Fprintf(stdout, "=== decomposition: %s ===\n", taskRef)
	if follow {
		if err := followRuntimeDecompositionLogFallback(config, plan, runner, stdout, taskRef, taskOutput, statusOutput, pollInterval); err != nil {
			return true, err
		}
		return true, nil
	}
	if state == "none" {
		fmt.Fprintf(stdout, "decomposition task=%s state=queued\n", taskRef)
		fmt.Fprintln(stdout, "decomposition_notice=no evidence has been written yet; the source ticket is waiting for the decomposition scheduler")
	} else if strings.TrimSpace(statusOutput) != "" {
		fmt.Fprintln(stdout, strings.TrimSpace(statusOutput))
	}
	return true, nil
}

func followRuntimeDecompositionLogFallback(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer, taskRef string, initialTaskOutput string, initialStatusOutput string, pollInterval time.Duration) error {
	lastStatusOutput := ""
	logOffsets := map[string]int64{}
	taskOutput := initialTaskOutput
	statusOutput := initialStatusOutput
	lastAction := ""
	for {
		state := parseOutputValue(statusOutput, "state")
		if state == "none" {
			statusOutput = fmt.Sprintf("decomposition task=%s state=queued\n", taskRef)
		}
		trimmedStatus := strings.TrimSpace(statusOutput)
		if trimmedStatus != "" && trimmedStatus != lastStatusOutput {
			fmt.Fprintln(stdout, trimmedStatus)
			lastStatusOutput = trimmedStatus
		}
		stage := decompositionFollowStage(taskOutput, statusOutput)
		action := decompositionLogActionForStage(stage)
		if lastAction != "" && lastAction != action {
			if err := printRuntimeDecompositionDeltas(config, plan, runner, stdout, taskRef, lastAction, logOffsets, false); err != nil {
				return err
			}
		}
		if action != "" {
			if err := printRuntimeDecompositionDeltas(config, plan, runner, stdout, taskRef, action, logOffsets, true); err != nil {
				return err
			}
			lastAction = action
		}
		if decompositionFollowTerminal(state, taskOutput) {
			if lastAction != "" {
				if err := printRuntimeDecompositionDeltas(config, plan, runner, stdout, taskRef, lastAction, logOffsets, true); err != nil {
					return err
				}
			}
			return nil
		}
		time.Sleep(pollInterval)

		var err error
		taskOutput, err = runtimeDescribeSectionOutput(config, plan, runner, "task", "a3", "show-task", "--storage-backend", "json", "--storage-dir", plan.StorageDir, taskRef)
		if err != nil {
			return err
		}
		statusOutput, err = runtimeDescribeSectionOutput(config, plan, runner, "decomposition_status", "a3", "show-decomposition-status", "--storage-backend", "json", "--storage-dir", plan.StorageDir, taskRef)
		if err != nil {
			return err
		}
	}
}

func printRuntimeDecompositionDeltas(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer, taskRef string, action string, offsets map[string]int64, includeLiveLog bool) error {
	if err := printRuntimeDecompositionActionLogDelta(config, plan, runner, stdout, action, offsets); err != nil {
		return err
	}
	if err := printRuntimeDecompositionAgentEventDelta(stdout, plan, taskRef, action, offsets); err != nil {
		return err
	}
	if includeLiveLog && decompositionAgentEventSeen(plan.HostAgentLog, taskRef, action, "command_start") {
		if err := printRuntimeDecompositionLiveLogDelta(stdout, plan, taskRef, action, offsets); err != nil {
			return err
		}
	}
	return nil
}

func printRuntimeDecompositionActionLogDelta(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer, stage string, offsets map[string]int64) error {
	action := decompositionLogActionForStage(stage)
	if action == "" {
		return nil
	}
	actionPlan := decompositionRuntimeProcessPlan(config, plan, action)
	output := string(dockerComposeExecBestEffort(config, actionPlan, runner, "cat", actionPlan.RuntimeLog))
	if output == "" {
		return nil
	}
	offset := offsets[actionPlan.RuntimeLog]
	if offset > int64(len(output)) {
		offset = 0
	}
	if offset == int64(len(output)) {
		return nil
	}
	fmt.Fprintf(stdout, "=== decomposition log: %s ===\n", action)
	fmt.Fprint(stdout, output[int(offset):])
	if !strings.HasSuffix(output, "\n") {
		fmt.Fprintln(stdout)
	}
	offsets[actionPlan.RuntimeLog] = int64(len(output))
	return nil
}

func printRuntimeDecompositionLiveLogDelta(stdout io.Writer, plan runtimeRunOncePlan, taskRef string, action string, offsets map[string]int64) error {
	if decompositionLogActionForStage(action) == "" {
		return nil
	}
	livePath := plan.preferredLiveLogPath(taskRef, "decomposition_"+action)
	offsetKey := "decomposition-live|" + action + "|" + livePath
	offset := offsets[offsetKey]
	nextOffset, err := printFileDeltaWithHeader(stdout, livePath, offset, fmt.Sprintf("=== decomposition live log: %s ===\n", action))
	if err != nil {
		return err
	}
	offsets[offsetKey] = nextOffset
	return nil
}

func printRuntimeDecompositionAgentEventDelta(stdout io.Writer, plan runtimeRunOncePlan, taskRef string, action string, offsets map[string]int64) error {
	if decompositionLogActionForStage(action) == "" {
		return nil
	}
	content, err := os.ReadFile(plan.HostAgentLog)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	offsetKey := "decomposition-agent|" + action + "|" + plan.HostAgentLog
	offset := offsets[offsetKey]
	if offset > int64(len(content)) {
		offset = 0
	}
	if offset == int64(len(content)) {
		return nil
	}
	lines := strings.Split(string(content[int(offset):]), "\n")
	var matched []string
	for _, line := range lines {
		if decompositionAgentEventMatches(line, taskRef, action) {
			matched = append(matched, line)
		}
	}
	if len(matched) > 0 {
		fmt.Fprintf(stdout, "=== decomposition agent events: %s ===\n", action)
		for _, line := range matched {
			fmt.Fprintln(stdout, line)
		}
	}
	offsets[offsetKey] = int64(len(content))
	return nil
}

func decompositionAgentEventMatches(line string, taskRef string, action string) bool {
	return decompositionAgentEventMatchesStage(line, taskRef, action, "")
}

func decompositionAgentEventSeen(hostAgentLog string, taskRef string, action string, stage string) bool {
	content, err := os.ReadFile(hostAgentLog)
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(content), "\n") {
		if decompositionAgentEventMatchesStage(line, taskRef, action, stage) {
			return true
		}
	}
	return false
}

func decompositionAgentEventMatchesStage(line string, taskRef string, action string, stage string) bool {
	const prefix = "a2o_agent_job_event "
	if !strings.Contains(line, prefix) {
		return false
	}
	raw := strings.TrimSpace(line[strings.Index(line, prefix)+len(prefix):])
	var payload map[string]any
	if err := json.Unmarshal([]byte(raw), &payload); err != nil {
		return false
	}
	if payload["task_ref"] != taskRef || payload["command_intent"] != "decomposition_"+action {
		return false
	}
	return stage == "" || payload["stage"] == stage
}

func decompositionFollowStage(taskOutput string, statusOutput string) string {
	stage := parseOutputValue(statusOutput, "stage")
	if stage != "" {
		return stage
	}
	taskStatus := strings.ToLower(strings.TrimSpace(parseOutputValue(taskOutput, "status")))
	if taskStatus == "in_review" {
		return "review"
	}
	if taskStatus == "in_progress" {
		switch {
		case parseOutputValue(statusOutput, "disposition") == "eligible":
			return "create_children"
		case strings.Contains(statusOutput, "evidence.proposal="):
			return "review"
		case strings.Contains(statusOutput, "evidence.investigation="):
			return "propose"
		default:
			return "investigate"
		}
	}
	if strings.Contains(statusOutput, "evidence.proposal_review=") && parseOutputValue(statusOutput, "disposition") == "eligible" {
		return "create_children"
	}
	if strings.Contains(statusOutput, "evidence.proposal=") {
		return "review"
	}
	if strings.Contains(statusOutput, "evidence.investigation=") {
		return "propose"
	}
	return ""
}

func decompositionLogActionForStage(stage string) string {
	switch strings.ToLower(strings.TrimSpace(stage)) {
	case "investigate":
		return "investigate"
	case "propose":
		return "propose"
	case "review":
		return "review"
	default:
		return ""
	}
}

func decompositionFollowTerminal(state string, taskOutput string) bool {
	switch strings.ToLower(strings.TrimSpace(state)) {
	case "done", "blocked":
		return true
	}
	if parseOutputValue(taskOutput, "runnable_reason") == "decomposition_requested" {
		return false
	}
	return !runtimeLogsShouldKeepFollowing(parseOutputValue(taskOutput, "status"))
}

type runtimeDecompositionSelection struct {
	TaskRef       string
	ActiveTaskRef string
}

func runAutomaticRuntimeDecompositionIfReady(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner, stdout io.Writer) (bool, error) {
	selection, err := planNextRuntimeDecomposition(config, plan, runner)
	if err != nil {
		return false, err
	}
	if selection.ActiveTaskRef != "" {
		fmt.Fprintf(stdout, "kanban_run_once=decomposition active=%s\n", selection.ActiveTaskRef)
		return true, nil
	}
	if selection.TaskRef == "" {
		return false, nil
	}

	fmt.Fprintf(stdout, "kanban_run_once=decomposition task=%s\n", selection.TaskRef)
	for _, action := range []string{"investigate", "propose", "review"} {
		command, err := runtimeDecompositionCommand(action, selection.TaskRef, plan, normalizeRuntimeDecompositionRepoSources(plan, nil), runtimeDecompositionOverrides{})
		if err != nil {
			return true, err
		}
		if err := runRuntimeDecompositionWithHostAgent(config, plan, command, action, runner, stdout); err != nil {
			return true, err
		}
	}
	return true, nil
}

func planNextRuntimeDecomposition(config runtimeInstanceConfig, plan runtimeRunOncePlan, runner commandRunner) (runtimeDecompositionSelection, error) {
	args := []string{"a3", "plan-next-decomposition-task", "--storage-backend", "json", "--storage-dir", plan.StorageDir}
	args = append(args, runtimeDecompositionKanbanOptions(plan)...)
	args = append(args, "--kanban-trigger-label", "trigger:investigate")
	output, err := dockerComposeExecOutput(config, plan, runner, runtimeInspectionArgs(args...)...)
	if err != nil {
		return runtimeDecompositionSelection{}, fmt.Errorf("plan next decomposition task failed: %w", err)
	}
	return parseRuntimeDecompositionSelection(string(output)), nil
}

func parseRuntimeDecompositionSelection(output string) runtimeDecompositionSelection {
	selection := runtimeDecompositionSelection{}
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(line, "active decomposition "):
			selection.ActiveTaskRef = strings.TrimSpace(strings.TrimPrefix(line, "active decomposition "))
		case strings.HasPrefix(line, "next decomposition "):
			selection.TaskRef = strings.TrimSpace(strings.TrimPrefix(line, "next decomposition "))
		}
	}
	return selection
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
