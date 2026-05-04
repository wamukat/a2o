package agent

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
)

type CompletionHookReport struct {
	Status  string                `json:"status"`
	Entries []CompletionHookEntry `json:"entries"`
}

type CompletionHookEntry struct {
	Name       string `json:"name"`
	Command    string `json:"command"`
	Mode       string `json:"mode"`
	Slot       string `json:"slot"`
	ExitStatus int    `json:"exit_status"`
	Stdout     string `json:"stdout"`
	Stderr     string `json:"stderr"`
	Status     string `json:"status"`
	Reason     string `json:"reason,omitempty"`
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
	for _, hook := range request.CompletionHooks {
		for _, slotName := range editSlots {
			entry, err := runCompletionHook(prepared, request, slotPaths, slotName, hook)
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

func runCompletionHook(prepared PreparedWorkspace, request WorkspaceRequest, slotPaths map[string]string, slotName string, hook WorkspaceCompletionHook) (CompletionHookEntry, error) {
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

	entry := executeCompletionHook(prepared, request, slotPaths[slotName], slotName, hook)
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

func executeCompletionHook(prepared PreparedWorkspace, request WorkspaceRequest, runtimePath, slotName string, hook WorkspaceCompletionHook) CompletionHookEntry {
	cmd := exec.Command("sh", "-c", hook.Command)
	cmd.Dir = runtimePath
	cmd.Env = append(os.Environ(),
		"A2O_WORKSPACE_ROOT="+prepared.Root,
		"A2O_COMPLETION_HOOK_NAME="+hook.Name,
		"A2O_COMPLETION_HOOK_MODE="+hook.Mode,
		"A2O_COMPLETION_HOOK_SLOT="+slotName,
		"A2O_COMPLETION_HOOK_SLOT_PATH="+runtimePath,
		"A2O_TASK_REF="+request.WorkspaceID,
	)
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	exitStatus := 0
	status := "succeeded"
	reason := ""
	if err != nil {
		status = "failed"
		reason = err.Error()
		exitStatus = 1
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitStatus = exitErr.ExitCode()
		}
	}
	return CompletionHookEntry{
		Name:       hook.Name,
		Command:    hook.Command,
		Mode:       hook.Mode,
		Slot:       slotName,
		ExitStatus: exitStatus,
		Stdout:     stdout.String(),
		Stderr:     stderr.String(),
		Status:     status,
		Reason:     reason,
	}
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

func failedCompletionHookEntry(slotName string, hook WorkspaceCompletionHook, reason string) CompletionHookEntry {
	return CompletionHookEntry{
		Name:       hook.Name,
		Command:    hook.Command,
		Mode:       hook.Mode,
		Slot:       slotName,
		ExitStatus: -1,
		Status:     "failed",
		Reason:     reason,
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
