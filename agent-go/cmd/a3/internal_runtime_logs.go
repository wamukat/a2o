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
	"strings"
	"time"
)

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
			if len(manifest.CompletedArtifacts) == 0 && !manifest.Active {
				if printed, err := printRuntimeDecompositionLogFallback(effectiveConfig, plan, runner, stdout, taskRef, *follow, *pollInterval); err != nil {
					return err
				} else if printed {
					return nil
				}
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
	return printFileDeltaWithHeader(stdout, livePath, offset, "")
}

func printFileDeltaWithHeader(stdout io.Writer, livePath string, offset int64, header string) (int64, error) {
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
	if info.Size() == offset {
		return offset, nil
	}
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		return offset, err
	}
	if header != "" {
		fmt.Fprint(stdout, header)
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
