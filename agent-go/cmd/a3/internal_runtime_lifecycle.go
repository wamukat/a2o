package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

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
