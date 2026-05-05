package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

var standardCompletionHookPathDirs = []string{
	"/opt/homebrew/bin",
	"/usr/local/bin",
	"/usr/bin",
	"/bin",
	"/usr/sbin",
	"/sbin",
}

type CompletionHookReport struct {
	Status  string                `json:"status"`
	Entries []CompletionHookEntry `json:"entries"`
}

type CompletionHookEntry struct {
	Name           string `json:"name"`
	Command        string `json:"command"`
	Mode           string `json:"mode"`
	Slot           string `json:"slot"`
	WorkingDir     string `json:"working_dir,omitempty"`
	WorkspaceRoot  string `json:"workspace_root,omitempty"`
	Path           string `json:"path,omitempty"`
	ShellPath      string `json:"shell_path,omitempty"`
	ExecutablePath string `json:"executable_path,omitempty"`
	ExitStatus     int    `json:"exit_status"`
	Stdout         string `json:"stdout"`
	Stderr         string `json:"stderr"`
	Status         string `json:"status"`
	Reason         string `json:"reason,omitempty"`
}

func (r CompletionHookReport) Ran() bool {
	return len(r.Entries) > 0
}

func (r CompletionHookReport) JSON() ([]byte, error) {
	content, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(content, '\n'), nil
}

func (r CompletionHookReport) FailingEntry() *CompletionHookEntry {
	for index := range r.Entries {
		if r.Entries[index].Status == "failed" {
			return &r.Entries[index]
		}
	}
	return nil
}

func RunCompletionHooks(prepared PreparedWorkspace, request WorkspaceRequest) (CompletionHookReport, error) {
	return RunCompletionHooksWithContext(context.Background(), prepared, request)
}

func RunCompletionHooksWithContext(ctx context.Context, prepared PreparedWorkspace, request WorkspaceRequest, jobEnv ...map[string]string) (CompletionHookReport, error) {
	report := CompletionHookReport{Status: "skipped"}
	if len(request.CompletionHooks) == 0 {
		return report, nil
	}
	slotPaths, err := requiredSlotRuntimePaths(prepared, request)
	if err != nil {
		report.Status = "failed"
		return report, err
	}
	editSlots := completionHookEditSlots(request, slotPaths)
	if len(editSlots) == 0 {
		report.Status = "succeeded"
		return report, nil
	}
	report.Status = "succeeded"
	hookEnv := mergeCompletionHookJobEnv(jobEnv...)
	for _, hook := range request.CompletionHooks {
		for _, slotName := range editSlots {
			entry, err := runCompletionHook(ctx, prepared, request, hookEnv, slotPaths, slotName, hook)
			report.Entries = append(report.Entries, entry)
			recordCompletionHookEntry(prepared, slotName, entry)
			if err != nil {
				report.Status = "failed"
				markCompletionHooksFailed(prepared, entry)
				return report, err
			}
		}
	}
	markCompletionHooksSucceeded(prepared)
	return report, nil
}

func CompletionHookContext(timeoutSeconds int, startedAt time.Time) (context.Context, context.CancelFunc) {
	if timeoutSeconds <= 0 {
		return context.WithCancel(context.Background())
	}
	deadline := startedAt.Add(time.Duration(timeoutSeconds) * time.Second)
	return context.WithDeadline(context.Background(), deadline)
}

func PublishCompletionHookAttempt(prepared PreparedWorkspace, request WorkspaceRequest) error {
	message := "A2O completion hook attempt"
	if strings.TrimSpace(request.WorkspaceID) != "" {
		message += " for " + strings.TrimSpace(request.WorkspaceID)
	}
	return publishAllEditTargetWorkspaceChanges(prepared, request, message, "bypass", nil)
}

func requiredSlotRuntimePaths(prepared PreparedWorkspace, request WorkspaceRequest) (map[string]string, error) {
	slotNames := make([]string, 0, len(request.Slots))
	for slotName := range request.Slots {
		slotNames = append(slotNames, slotName)
	}
	sort.Strings(slotNames)
	result := map[string]string{}
	for _, slotName := range slotNames {
		slot := request.Slots[slotName]
		if !slot.Required {
			continue
		}
		descriptor := prepared.SlotDescriptors[slotName]
		if descriptor == nil {
			return nil, fmt.Errorf("workspace descriptor missing slot %s", slotName)
		}
		runtimePath, ok := descriptor["runtime_path"].(string)
		if !ok || runtimePath == "" {
			return nil, fmt.Errorf("slot descriptor runtime_path is required for %s", slotName)
		}
		result[slotName] = runtimePath
	}
	return result, nil
}

func completionHookEditSlots(request WorkspaceRequest, slotPaths map[string]string) []string {
	slots := []string{}
	for slotName, slot := range request.Slots {
		if !slot.Required || slot.Access != "read_write" || slot.Ownership != "edit_target" {
			continue
		}
		if _, ok := slotPaths[slotName]; ok {
			slots = append(slots, slotName)
		}
	}
	sort.Strings(slots)
	return slots
}

func runCompletionHook(ctx context.Context, prepared PreparedWorkspace, request WorkspaceRequest, jobEnv map[string]string, slotPaths map[string]string, slotName string, hook WorkspaceCompletionHook) (CompletionHookEntry, error) {
	beforeStates, err := gitStates(slotPaths)
	if err != nil {
		return failedCompletionHookEntry(slotName, hook, "snapshot failed: "+err.Error()), err
	}
	snapshots, err := captureCompletionHookSnapshots(slotPaths)
	if err != nil {
		return failedCompletionHookEntry(slotName, hook, "snapshot failed: "+err.Error()), err
	}
	dropSnapshots := true
	defer func() {
		if dropSnapshots {
			_ = dropCompletionHookSnapshots(snapshots)
		}
	}()

	entry := executeCompletionHook(ctx, prepared, request, jobEnv, slotPaths[slotName], slotName, hook)
	afterStates, stateErr := gitStates(slotPaths)
	if entry.Status == "succeeded" && stateErr != nil {
		entry.Status = "failed"
		entry.Reason = "post-hook state failed: " + stateErr.Error()
	}
	if entry.Status == "succeeded" {
		if reason := completionHookStateViolation(slotName, hook, beforeStates, afterStates); reason != "" {
			entry.Status = "failed"
			entry.Reason = reason
		}
	}
	if entry.Status == "failed" {
		dropSnapshots = false
		restoreErr := restoreCompletionHookSnapshots(snapshots)
		dropErr := dropCompletionHookSnapshots(snapshots)
		dropSnapshots = true
		if restoreErr != nil {
			if entry.Reason == "" {
				entry.Reason = restoreErr.Error()
			} else {
				entry.Reason += "; restore failed: " + restoreErr.Error()
			}
		}
		if dropErr != nil {
			entry.Reason += "; snapshot cleanup failed: " + dropErr.Error()
		}
		return entry, fmt.Errorf("completion hook %s failed for slot %s: %s", hook.Name, slotName, entry.Reason)
	}
	return entry, nil
}

func executeCompletionHook(ctx context.Context, prepared PreparedWorkspace, request WorkspaceRequest, jobEnv map[string]string, runtimePath, slotName string, hook WorkspaceCompletionHook) CompletionHookEntry {
	pathValue := completionHookPath(completionHookBasePath(jobEnv))
	shellPath := completionHookLookPath("sh", pathValue)
	command := expandCompletionHookCommand(hook.Command, prepared, jobEnv, runtimePath, slotName)
	executablePath := completionHookExecutablePath(command, pathValue)
	shellCommand := shellPath
	if shellCommand == "" {
		shellCommand = "sh"
	}
	cmd := exec.CommandContext(ctx, shellCommand, "-c", command)
	cmd.Dir = runtimePath
	cmd.Env = completionHookEnv(os.Environ(), pathValue, jobEnv,
		"A2O_WORKSPACE_ROOT="+prepared.Root,
		"A2O_COMPLETION_HOOK_NAME="+hook.Name,
		"A2O_COMPLETION_HOOK_MODE="+hook.Mode,
		"A2O_COMPLETION_HOOK_SLOT="+slotName,
		"A2O_COMPLETION_HOOK_SLOT_PATH="+runtimePath,
		"A2O_TASK_REF="+request.WorkspaceID,
	)
	stdoutFile, stdoutPath, stdoutErr := completionHookOutputFile("stdout")
	if stdoutErr != nil {
		return failedCompletionHookEntry(slotName, hook, "stdout capture failed: "+stdoutErr.Error(), runtimePath, prepared.Root, pathValue, shellPath, executablePath)
	}
	defer os.Remove(stdoutPath)
	defer stdoutFile.Close()
	stderrFile, stderrPath, stderrErr := completionHookOutputFile("stderr")
	if stderrErr != nil {
		return failedCompletionHookEntry(slotName, hook, "stderr capture failed: "+stderrErr.Error(), runtimePath, prepared.Root, pathValue, shellPath, executablePath)
	}
	defer os.Remove(stderrPath)
	defer stderrFile.Close()
	cmd.Stdout = stdoutFile
	cmd.Stderr = stderrFile
	err := runCompletionHookCommand(ctx, cmd)
	stdout := readCompletionHookOutput(stdoutFile, stdoutPath)
	stderr := readCompletionHookOutput(stderrFile, stderrPath)
	exitStatus := 0
	status := "succeeded"
	reason := ""
	if err != nil {
		status = "failed"
		reason = err.Error()
		exitStatus = 1
		if ctx.Err() == context.DeadlineExceeded {
			reason = "completion hook timed out"
			exitStatus = -1
			stderr += "A2O completion hook timed out\n"
		} else if exitErr, ok := err.(*exec.ExitError); ok {
			exitStatus = exitErr.ExitCode()
		}
	}
	return CompletionHookEntry{
		Name:           hook.Name,
		Command:        command,
		Mode:           hook.Mode,
		Slot:           slotName,
		WorkingDir:     runtimePath,
		WorkspaceRoot:  prepared.Root,
		Path:           pathValue,
		ShellPath:      shellPath,
		ExecutablePath: executablePath,
		ExitStatus:     exitStatus,
		Stdout:         stdout,
		Stderr:         stderr,
		Status:         status,
		Reason:         reason,
	}
}

func completionHookPath(raw string) string {
	seen := map[string]bool{}
	parts := []string{}
	for _, part := range filepath.SplitList(raw) {
		if part == "" || seen[part] {
			continue
		}
		seen[part] = true
		parts = append(parts, part)
	}
	for _, part := range standardCompletionHookPathDirs {
		if part == "" || seen[part] {
			continue
		}
		seen[part] = true
		parts = append(parts, part)
	}
	return strings.Join(parts, string(os.PathListSeparator))
}

func completionHookEnv(base []string, pathValue string, jobEnv map[string]string, extra ...string) []string {
	env := make([]string, 0, len(base)+len(jobEnv)+len(extra)+1)
	replacedPath := false
	for _, item := range base {
		if strings.HasPrefix(item, "PATH=") {
			env = append(env, "PATH="+pathValue)
			replacedPath = true
			continue
		}
		env = append(env, item)
	}
	for _, key := range sortedMapKeysString(jobEnv) {
		if key == "" || strings.Contains(key, "=") {
			continue
		}
		if key == "PATH" {
			continue
		}
		env = append(env, key+"="+jobEnv[key])
	}
	if !replacedPath {
		env = append(env, "PATH="+pathValue)
	}
	env = append(env, extra...)
	return env
}

func mergeCompletionHookJobEnv(values ...map[string]string) map[string]string {
	merged := map[string]string{}
	for _, value := range values {
		for key, item := range value {
			merged[key] = item
		}
	}
	return merged
}

func completionHookBasePath(jobEnv map[string]string) string {
	if value := strings.TrimSpace(jobEnv["PATH"]); value != "" {
		return value
	}
	return os.Getenv("PATH")
}

func expandCompletionHookCommand(command string, prepared PreparedWorkspace, jobEnv map[string]string, runtimePath string, slotName string) string {
	rootDir := strings.TrimSpace(jobEnv["A2O_ROOT_DIR"])
	if rootDir == "" {
		rootDir = strings.TrimSpace(jobEnv["A3_ROOT_DIR"])
	}
	if rootDir == "" {
		rootDir = prepared.Root
	}
	replacer := strings.NewReplacer(
		"{{a2o_root_dir}}", rootDir,
		"{{workspace_root}}", prepared.Root,
		"{{slot_path}}", runtimePath,
		"{{slot}}", slotName,
	)
	return replacer.Replace(command)
}

func sortedMapKeysString(values map[string]string) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func completionHookExecutablePath(command string, pathValue string) string {
	fields := strings.Fields(strings.TrimSpace(command))
	if len(fields) == 0 {
		return ""
	}
	executable := fields[0]
	if strings.Contains(executable, "/") {
		return executable
	}
	return completionHookLookPath(executable, pathValue)
}

func completionHookLookPath(executable string, pathValue string) string {
	if executable == "" {
		return ""
	}
	if strings.Contains(executable, "/") {
		if completionHookExecutableFile(executable) {
			return executable
		}
		return ""
	}
	for _, dir := range filepath.SplitList(pathValue) {
		if dir == "" {
			continue
		}
		candidate := filepath.Join(dir, executable)
		if completionHookExecutableFile(candidate) {
			return candidate
		}
	}
	return ""
}

func completionHookExecutableFile(path string) bool {
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return false
	}
	return info.Mode().Perm()&0o111 != 0
}

func completionHookOutputFile(stream string) (*os.File, string, error) {
	file, err := os.CreateTemp("", "a2o-completion-hook-"+stream+"-*")
	if err != nil {
		return nil, "", err
	}
	return file, file.Name(), nil
}

func readCompletionHookOutput(file *os.File, path string) string {
	_ = file.Close()
	content, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(content)
}

func runCompletionHookCommand(ctx context.Context, cmd *exec.Cmd) error {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.WaitDelay = time.Second
	cmd.Cancel = func() error {
		if cmd.Process != nil {
			var groupErr error
			if err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL); err != nil && !errors.Is(err, syscall.ESRCH) {
				groupErr = err
			}
			if err := cmd.Process.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) && groupErr == nil {
				return err
			}
			return groupErr
		}
		return nil
	}
	return cmd.Run()
}

func completionHookStateViolation(slotName string, hook WorkspaceCompletionHook, before, after map[string]preflightGitState) string {
	for candidate, beforeState := range before {
		afterState := after[candidate]
		if candidate != slotName && afterState != beforeState {
			return fmt.Sprintf("mutated non-target slot %s", candidate)
		}
		if candidate == slotName && hook.Mode == "check" && afterState != beforeState {
			return fmt.Sprintf("mutated slot %s in check mode", candidate)
		}
	}
	return ""
}

type completionHookSnapshot struct {
	root    string
	created bool
}

func captureCompletionHookSnapshots(slotPaths map[string]string) ([]completionHookSnapshot, error) {
	slotNames := sortedMapKeys(slotPaths)
	snapshots := make([]completionHookSnapshot, 0, len(slotNames))
	for _, slotName := range slotNames {
		root := slotPaths[slotName]
		before, _ := gitOutput(root, "rev-parse", "--verify", "refs/stash")
		out, err := gitOutput(root, "stash", "push", "--include-untracked", "--message", "a2o completion hook snapshot")
		if err != nil {
			return snapshots, err
		}
		after, _ := gitOutput(root, "rev-parse", "--verify", "refs/stash")
		created := after != "" && after != before && !strings.Contains(out, "No local changes")
		snapshot := completionHookSnapshot{root: root, created: created}
		snapshots = append(snapshots, snapshot)
		if created {
			if err := runGit(root, "stash", "apply", "--index", "stash@{0}"); err != nil {
				return snapshots, err
			}
		}
	}
	return snapshots, nil
}

func restoreCompletionHookSnapshots(snapshots []completionHookSnapshot) error {
	var errs []error
	for _, snapshot := range snapshots {
		errs = append(errs, runGit(snapshot.root, "reset", "--hard", "HEAD"))
		errs = append(errs, runGit(snapshot.root, "clean", "-fd"))
		if snapshot.created {
			errs = append(errs, runGit(snapshot.root, "stash", "apply", "--index", "stash@{0}"))
		}
	}
	return joinErrors(errs)
}

func dropCompletionHookSnapshots(snapshots []completionHookSnapshot) error {
	var errs []error
	for _, snapshot := range snapshots {
		if snapshot.created {
			errs = append(errs, runGit(snapshot.root, "stash", "drop", "stash@{0}"))
		}
	}
	return joinErrors(errs)
}

func gitStates(slotPaths map[string]string) (map[string]preflightGitState, error) {
	states := map[string]preflightGitState{}
	for _, slotName := range sortedMapKeys(slotPaths) {
		state, err := gitPreflightState(slotPaths[slotName])
		if err != nil {
			return nil, err
		}
		states[slotName] = state
	}
	return states, nil
}

func sortedMapKeys(values map[string]string) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func failedCompletionHookEntry(slotName string, hook WorkspaceCompletionHook, reason string, details ...string) CompletionHookEntry {
	workingDir := ""
	workspaceRoot := ""
	pathValue := ""
	shellPath := ""
	executablePath := ""
	if len(details) > 0 {
		workingDir = details[0]
	}
	if len(details) > 1 {
		workspaceRoot = details[1]
	}
	if len(details) > 2 {
		pathValue = details[2]
	}
	if len(details) > 3 {
		shellPath = details[3]
	}
	if len(details) > 4 {
		executablePath = details[4]
	}
	return CompletionHookEntry{
		Name:           hook.Name,
		Command:        hook.Command,
		Mode:           hook.Mode,
		Slot:           slotName,
		WorkingDir:     workingDir,
		WorkspaceRoot:  workspaceRoot,
		Path:           pathValue,
		ShellPath:      shellPath,
		ExecutablePath: executablePath,
		ExitStatus:     -1,
		Status:         "failed",
		Reason:         reason,
	}
}

func recordCompletionHookEntry(prepared PreparedWorkspace, slotName string, entry CompletionHookEntry) {
	descriptor := prepared.SlotDescriptors[slotName]
	if descriptor == nil {
		return
	}
	existing, _ := descriptor["completion_hook_logs"].([]CompletionHookEntry)
	descriptor["completion_hook_logs"] = append(existing, entry)
	descriptor["completion_hook_status"] = entry.Status
}

func markCompletionHooksSucceeded(prepared PreparedWorkspace) {
	for _, descriptor := range prepared.SlotDescriptors {
		if _, ok := descriptor["completion_hook_logs"]; ok {
			descriptor["completion_hook_status"] = "succeeded"
		}
	}
}

func markCompletionHooksFailed(prepared PreparedWorkspace, entry CompletionHookEntry) {
	for _, descriptor := range prepared.SlotDescriptors {
		if _, ok := descriptor["completion_hook_logs"]; ok {
			descriptor["completion_hook_status"] = "failed"
			descriptor["completion_hook_failed_name"] = entry.Name
			descriptor["completion_hook_failed_slot"] = entry.Slot
			descriptor["completion_hook_failed_reason"] = entry.Reason
		}
	}
}

func joinErrors(errs []error) error {
	messages := []string{}
	for _, err := range errs {
		if err != nil {
			messages = append(messages, err.Error())
		}
	}
	if len(messages) == 0 {
		return nil
	}
	return errors.New(strings.Join(messages, "; "))
}
