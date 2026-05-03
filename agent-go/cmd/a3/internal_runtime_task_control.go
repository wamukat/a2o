package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
)

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
