package agent

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

type WorkspaceMaterializer struct {
	WorkspaceRoot string
	SourceAliases map[string]string
}

type PreparedWorkspace struct {
	Root              string
	SlotDescriptors   map[string]map[string]any
	cleanupOperations []cleanupOperation
}

type cleanupOperation struct {
	sourceRoot string
	slotPath   string
}

type publishPlan struct {
	slotName    string
	runtimePath string
	declared    []string
	skipped     bool
	noChanges   bool
}

type mergePlan struct {
	slotName    string
	sourceRoot  string
	worktree    string
	sourceRef   string
	targetRef   string
	beforeHead  string
	afterHead   string
	descriptor  map[string]any
	initialized bool
	createdRef  bool
}

type mergeConflictError struct {
	plan mergePlan
	err  error
}

type unmergedFile struct {
	status string
	path   string
}

func (e mergeConflictError) Error() string {
	return e.err.Error()
}

func (e mergeConflictError) Unwrap() error {
	return e.err
}

func (m WorkspaceMaterializer) Prepare(request WorkspaceRequest) (PreparedWorkspace, error) {
	root, err := m.workspaceRoot(request.WorkspaceID)
	if err != nil {
		return PreparedWorkspace{}, err
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return PreparedWorkspace{}, err
	}

	prepared := PreparedWorkspace{
		Root:            root,
		SlotDescriptors: map[string]map[string]any{},
	}
	for slotName, slot := range request.Slots {
		if !slot.Required {
			continue
		}
		if slot.Source.Kind != "local_git" {
			return PreparedWorkspace{}, fmt.Errorf("unsupported source kind for %s: %s", slotName, slot.Source.Kind)
		}
		if slot.Checkout != "worktree_branch" {
			return PreparedWorkspace{}, fmt.Errorf("unsupported checkout for %s: %s", slotName, slot.Checkout)
		}
		if !validSyncClass(slot.SyncClass) {
			return PreparedWorkspace{}, fmt.Errorf("unsupported sync_class for %s: %s", slotName, slot.SyncClass)
		}
		if !validOwnership(slot.Ownership) {
			return PreparedWorkspace{}, fmt.Errorf("unsupported ownership for %s: %s", slotName, slot.Ownership)
		}
		if _, err := branchNameForRef(slot.Ref); err != nil {
			return PreparedWorkspace{}, fmt.Errorf("unsupported branch ref for %s: %s", slotName, slot.Ref)
		}
		sourceRoot, err := m.sourceRoot(slot.Source.Alias)
		if err != nil {
			return PreparedWorkspace{}, err
		}
		slotPath := filepath.Join(root, slotDirectory(slotName))
		descriptor, err := m.materializeSlot(sourceRoot, slotPath, slot)
		if err != nil {
			return PreparedWorkspace{}, err
		}
		if err := writeSlotMetadata(slotPath, sourceRoot, request, slotName, slot); err != nil {
			return PreparedWorkspace{}, err
		}
		prepared.SlotDescriptors[slotName] = descriptor
		prepared.cleanupOperations = append(prepared.cleanupOperations, cleanupOperation{
			sourceRoot: sourceRoot,
			slotPath:   slotPath,
		})
	}
	if err := writeWorkspaceMetadata(root, request); err != nil {
		return PreparedWorkspace{}, err
	}
	return prepared, nil
}

func validSyncClass(value string) bool {
	return value == "eager" || value == "lazy_but_guaranteed"
}

func validOwnership(value string) bool {
	return value == "edit_target" || value == "support"
}

func (m WorkspaceMaterializer) Merge(request MergeRequest) (WorkspaceDescriptor, ExecutionResult) {
	descriptor := WorkspaceDescriptor{
		WorkspaceKind:    "runtime_workspace",
		RuntimeProfile:   "",
		WorkspaceID:      request.WorkspaceID,
		SourceDescriptor: SourceDescriptor{WorkspaceKind: "runtime_workspace", SourceType: "branch_head"},
		SlotDescriptors:  map[string]map[string]any{},
	}
	plans, err := m.prepareMergePlans(request, descriptor.SlotDescriptors)
	if err != nil {
		return descriptor, failedMergeExecution(err)
	}
	if err := executeMergePlans(plans, request.Policy); err != nil {
		return descriptor, failedMergeExecution(err)
	}
	return descriptor, ExecutionResult{Status: "succeeded", ExitCode: intPtr(0), CombinedLog: []byte("A3 agent merge completed\n")}
}

func (m WorkspaceMaterializer) prepareMergePlans(request MergeRequest, descriptors map[string]map[string]any) ([]mergePlan, error) {
	if request.WorkspaceID == "" {
		return nil, fmt.Errorf("merge workspace_id is required")
	}
	if request.Policy == "" {
		return nil, fmt.Errorf("merge policy is required")
	}
	if !validMergePolicy(request.Policy) {
		return nil, fmt.Errorf("unsupported merge policy: %s", request.Policy)
	}
	root, err := m.workspaceRoot(request.WorkspaceID)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return nil, err
	}
	slotNames := make([]string, 0, len(request.Slots))
	for slotName := range request.Slots {
		slotNames = append(slotNames, slotName)
	}
	sort.Strings(slotNames)
	plans := make([]mergePlan, 0, len(slotNames))
	for _, slotName := range slotNames {
		slot := request.Slots[slotName]
		if slot.Source.Kind != "local_git" {
			rollbackMergePlans(plans)
			return nil, fmt.Errorf("unsupported merge source kind for %s: %s", slotName, slot.Source.Kind)
		}
		if _, err := branchNameForRef(slot.TargetRef); err != nil {
			rollbackMergePlans(plans)
			return nil, fmt.Errorf("unsupported merge target ref for %s: %s", slotName, slot.TargetRef)
		}
		sourceRoot, err := m.sourceRoot(slot.Source.Alias)
		if err != nil {
			rollbackMergePlans(plans)
			return nil, err
		}
		if dirty, err := gitDirty(sourceRoot); err != nil {
			rollbackMergePlans(plans)
			return nil, err
		} else if dirty {
			rollbackMergePlans(plans)
			return nil, fmt.Errorf("source alias %s is dirty before merge", slot.Source.Alias)
		}
		beforeHead, createdRef, err := ensureMergeTargetRef(sourceRoot, slot.TargetRef, slot.BootstrapRef)
		if err != nil {
			rollbackMergePlans(plans)
			return nil, err
		}
		sourceHead, err := gitOutput(sourceRoot, "rev-parse", slot.SourceRef)
		if err != nil {
			rollbackMergePlans(append(plans, mergePlan{
				sourceRoot: sourceRoot,
				targetRef:  slot.TargetRef,
				beforeHead: beforeHead,
				createdRef: createdRef,
			}))
			return nil, err
		}
		worktree := filepath.Join(root, slotDirectory(slotName))
		if err := os.RemoveAll(worktree); err != nil {
			rollbackMergePlans(append(plans, mergePlan{
				sourceRoot: sourceRoot,
				targetRef:  slot.TargetRef,
				beforeHead: beforeHead,
				createdRef: createdRef,
			}))
			return nil, err
		}
		descriptor := map[string]any{
			"runtime_path":         worktree,
			"source_kind":          slot.Source.Kind,
			"source_alias":         slot.Source.Alias,
			"merge_source_ref":     slot.SourceRef,
			"merge_target_ref":     slot.TargetRef,
			"merge_before_head":    beforeHead,
			"source_head_commit":   sourceHead,
			"merge_policy":         request.Policy,
			"merge_status":         "prepared",
			"dirty_before":         false,
			"workspace_ownership":  "agent",
			"project_repo_mutator": "a3-agent",
		}
		descriptors[slotName] = descriptor
		plans = append(plans, mergePlan{
			slotName:   slotName,
			sourceRoot: sourceRoot,
			worktree:   worktree,
			sourceRef:  slot.SourceRef,
			targetRef:  slot.TargetRef,
			beforeHead: beforeHead,
			descriptor: descriptor,
			createdRef: createdRef,
		})
	}
	return plans, nil
}

func executeMergePlans(plans []mergePlan, policy string) error {
	merged := []mergePlan{}
	for _, plan := range plans {
		current := plan
		if err := runGit(current.sourceRoot, "worktree", "add", "--force", current.worktree, branchNameMust(current.targetRef)); err != nil {
			return errors.Join(err, rollbackMergePlans(append(merged, current)))
		}
		current.initialized = true
		if err := runGit(current.worktree, mergeGitArgs(policy, current.sourceRef)...); err != nil {
			if unmergedFiles, conflictErr := gitUnmergedFiles(current.worktree); conflictErr == nil && len(unmergedFiles) > 0 {
				conflictFiles := unmergedPaths(unmergedFiles)
				current.descriptor["merge_status"] = "conflicted"
				current.descriptor["merge_error"] = err.Error()
				current.descriptor["conflict_files"] = conflictFiles
				current.descriptor["conflict_statuses"] = unmergedStatuses(unmergedFiles)
				if recoverableContentConflict(unmergedFiles) {
					current.descriptor["merge_recovery_candidate"] = true
					current.descriptor["merge_recovery_workspace_retained"] = true
					current.descriptor["resolved_conflict_files"] = []string{}
					return errors.Join(mergeConflictError{plan: current, err: err}, rollbackMergePlans(merged))
				}
				rollbackErr := rollbackMergePlans(append(merged, current))
				current.descriptor["merge_status"] = "failed"
				current.descriptor["merge_recovery_candidate"] = false
				current.descriptor["merge_recovery_workspace_retained"] = false
				return errors.Join(err, rollbackErr)
			}
			return errors.Join(err, rollbackMergePlans(append(merged, current)))
		}
		afterHead, err := gitOutput(current.worktree, "rev-parse", "HEAD")
		if err != nil {
			return errors.Join(err, rollbackMergePlans(append(merged, current)))
		}
		current.afterHead = afterHead
		current.descriptor["merge_after_head"] = afterHead
		current.descriptor["resolved_head"] = afterHead
		current.descriptor["merge_status"] = "merged"
		merged = append(merged, current)
	}
	if err := cleanupMergeWorktrees(merged); err != nil {
		return err
	}
	return refreshMergedSourceWorktrees(merged)
}

func refreshMergedSourceWorktrees(plans []mergePlan) error {
	var refreshErr error
	seen := map[string]bool{}
	for _, plan := range plans {
		key := plan.sourceRoot + "\x00" + plan.targetRef
		if seen[key] {
			continue
		}
		seen[key] = true
		currentRef, err := gitOutput(plan.sourceRoot, "symbolic-ref", "-q", "HEAD")
		if err != nil || currentRef != plan.targetRef {
			continue
		}
		refreshErr = errors.Join(refreshErr, runGit(plan.sourceRoot, "reset", "--hard", plan.targetRef))
	}
	return refreshErr
}

func rollbackMergePlans(plans []mergePlan) error {
	var rollbackErr error
	for index := len(plans) - 1; index >= 0; index-- {
		plan := plans[index]
		if plan.initialized {
			rollbackErr = errors.Join(rollbackErr, runGit(plan.worktree, "merge", "--abort"))
			rollbackErr = errors.Join(rollbackErr, runGit(plan.worktree, "reset", "--hard", plan.beforeHead))
			rollbackErr = errors.Join(rollbackErr, runGit(plan.sourceRoot, "worktree", "remove", "--force", plan.worktree))
		}
		if plan.createdRef {
			rollbackErr = errors.Join(rollbackErr, runGit(plan.sourceRoot, "update-ref", "-d", plan.targetRef))
		} else {
			rollbackErr = errors.Join(rollbackErr, runGit(plan.sourceRoot, "update-ref", plan.targetRef, plan.beforeHead))
		}
		if plan.descriptor != nil {
			plan.descriptor["merge_status"] = "rolled_back"
			delete(plan.descriptor, "merge_after_head")
			delete(plan.descriptor, "resolved_head")
		}
	}
	return rollbackErr
}

func cleanupMergeWorktrees(plans []mergePlan) error {
	var cleanupErr error
	for _, plan := range plans {
		if plan.initialized {
			cleanupErr = errors.Join(cleanupErr, runGit(plan.sourceRoot, "worktree", "remove", "--force", plan.worktree))
		}
	}
	return cleanupErr
}

func gitUnmergedFiles(root string) ([]unmergedFile, error) {
	out, err := gitOutput(root, "status", "--porcelain")
	if err != nil {
		return nil, err
	}
	if out == "" {
		return []unmergedFile{}, nil
	}
	files := []unmergedFile{}
	for _, line := range strings.FieldsFunc(out, func(char rune) bool { return char == '\n' || char == '\r' }) {
		if len(line) < 4 {
			continue
		}
		status := line[:2]
		if !unmergedStatus(status) {
			continue
		}
		files = append(files, unmergedFile{
			status: status,
			path:   strings.TrimSpace(line[3:]),
		})
	}
	sort.Slice(files, func(left, right int) bool {
		if files[left].path == files[right].path {
			return files[left].status < files[right].status
		}
		return files[left].path < files[right].path
	})
	return files, nil
}

func unmergedStatus(status string) bool {
	switch status {
	case "DD", "AU", "UD", "UA", "DU", "AA", "UU":
		return true
	default:
		return false
	}
}

func recoverableContentConflict(files []unmergedFile) bool {
	if len(files) == 0 {
		return false
	}
	for _, file := range files {
		if file.status != "UU" {
			return false
		}
	}
	return true
}

func unmergedPaths(files []unmergedFile) []string {
	paths := make([]string, 0, len(files))
	for _, file := range files {
		paths = append(paths, file.path)
	}
	sort.Strings(paths)
	return uniqueStrings(paths)
}

func unmergedStatuses(files []unmergedFile) map[string]string {
	statuses := make(map[string]string, len(files))
	for _, file := range files {
		statuses[file.path] = file.status
	}
	return statuses
}

func ensureMergeTargetRef(root, targetRef, bootstrapRef string) (string, bool, error) {
	head, err := gitOutput(root, "rev-parse", targetRef)
	if err == nil {
		return head, false, nil
	}
	if bootstrapRef == "" {
		return "", false, fmt.Errorf("merge target ref %s is missing and bootstrap_ref is not provided", targetRef)
	}
	bootstrapHead, err := gitOutput(root, "rev-parse", bootstrapRef)
	if err != nil {
		return "", false, err
	}
	if err := runGit(root, "update-ref", targetRef, bootstrapHead); err != nil {
		return "", false, err
	}
	return bootstrapHead, true, nil
}

func mergeGitArgs(policy, sourceRef string) []string {
	switch policy {
	case "ff_only":
		return []string{"merge", "--ff-only", sourceRef}
	case "ff_or_merge":
		return []string{"merge", "--no-edit", sourceRef}
	case "no_ff":
		return []string{"merge", "--no-ff", "--no-edit", sourceRef}
	default:
		return []string{"merge", "--ff-only", sourceRef}
	}
}

func validMergePolicy(policy string) bool {
	return policy == "ff_only" || policy == "ff_or_merge" || policy == "no_ff"
}

func branchNameMust(ref string) string {
	name, err := branchNameForRef(ref)
	if err != nil {
		return ref
	}
	return name
}

func failedMergeExecution(err error) ExecutionResult {
	return ExecutionResult{Status: "failed", ExitCode: intPtr(1), CombinedLog: []byte("A3 agent merge failed: " + err.Error() + "\n")}
}

func intPtr(value int) *int {
	return &value
}

func (m WorkspaceMaterializer) Cleanup(prepared PreparedWorkspace) error {
	var firstErr error
	for _, operation := range prepared.cleanupOperations {
		if err := runGit(operation.sourceRoot, "worktree", "remove", "--force", operation.slotPath); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	if err := os.RemoveAll(prepared.Root); err != nil && firstErr == nil {
		firstErr = err
	}
	return firstErr
}

func RefreshWorkspaceEvidence(prepared PreparedWorkspace) error {
	for _, descriptor := range prepared.SlotDescriptors {
		runtimePath, ok := descriptor["runtime_path"].(string)
		if !ok || runtimePath == "" {
			return fmt.Errorf("slot descriptor runtime_path is required")
		}
		changedFiles, err := gitChangedPaths(runtimePath)
		if err != nil {
			return err
		}
		patch, err := gitPatch(runtimePath)
		if err != nil {
			return err
		}
		dirtyAfter, err := gitDirtyIgnoringMetadata(runtimePath)
		if err != nil {
			return err
		}
		if publishedChangedFiles, ok := descriptor["published_changed_files"].([]string); ok {
			descriptor["changed_files"] = publishedChangedFiles
		} else {
			descriptor["changed_files"] = changedFiles
		}
		descriptor["patch"] = patch
		descriptor["dirty_after"] = dirtyAfter
	}
	return nil
}

func PublishWorkspaceChanges(prepared PreparedWorkspace, request WorkspaceRequest, workerProtocolResult map[string]any, commandSucceeded bool) error {
	policy := request.PublishPolicy
	if policy == nil {
		return nil
	}
	switch policy.Mode {
	case "commit_declared_changes_on_success":
		if workerProtocolResult == nil || workerProtocolResult["success"] != true {
			return nil
		}
		declaredChangedFiles, err := declaredChangedFilesBySlot(workerProtocolResult)
		if err != nil {
			return err
		}
		return publishDeclaredWorkspaceChanges(prepared, request, declaredChangedFiles, strings.TrimSpace(policy.CommitMessage))
	case "commit_all_edit_target_changes_on_worker_success":
		if workerProtocolResult == nil || workerProtocolResult["success"] != true {
			return nil
		}
		return publishAllEditTargetWorkspaceChanges(prepared, request, strings.TrimSpace(policy.CommitMessage))
	case "commit_all_edit_target_changes_on_success":
		if !commandSucceeded {
			return nil
		}
		return publishAllEditTargetWorkspaceChanges(prepared, request, strings.TrimSpace(policy.CommitMessage))
	default:
		return fmt.Errorf("unsupported publish policy mode: %s", policy.Mode)
	}
}

func publishDeclaredWorkspaceChanges(prepared PreparedWorkspace, request WorkspaceRequest, declaredChangedFiles map[string][]string, commitMessage string) error {
	plans, err := buildPublishPlans(prepared, request, func(slotName string, actual []string) ([]string, error) {
		declared := normalizePathList(declaredChangedFiles[slotName])
		if !sameStrings(actual, declared) {
			return nil, fmt.Errorf("slot %s changed files do not match worker result: actual=%v declared=%v", slotName, actual, declared)
		}
		return declared, nil
	})
	if err != nil {
		return err
	}
	return executePublishPlans(prepared, plans, commitMessage)
}

func publishAllEditTargetWorkspaceChanges(prepared PreparedWorkspace, request WorkspaceRequest, commitMessage string) error {
	plans, err := buildPublishPlans(prepared, request, func(_ string, actual []string) ([]string, error) {
		return normalizePathList(actual), nil
	})
	if err != nil {
		return err
	}
	return executePublishPlans(prepared, plans, commitMessage)
}

func buildPublishPlans(prepared PreparedWorkspace, request WorkspaceRequest, changedFilesFor func(string, []string) ([]string, error)) ([]publishPlan, error) {
	slotNames := make([]string, 0, len(request.Slots))
	for slotName := range request.Slots {
		slotNames = append(slotNames, slotName)
	}
	sort.Strings(slotNames)
	plans := make([]publishPlan, 0, len(slotNames))
	for _, slotName := range slotNames {
		slot := request.Slots[slotName]
		descriptor := prepared.SlotDescriptors[slotName]
		if descriptor == nil {
			return nil, fmt.Errorf("workspace descriptor missing slot %s", slotName)
		}
		runtimePath, ok := descriptor["runtime_path"].(string)
		if !ok || runtimePath == "" {
			return nil, fmt.Errorf("slot descriptor runtime_path is required for %s", slotName)
		}
		actual, err := gitChangedPaths(runtimePath)
		if err != nil {
			return nil, err
		}
		if slot.Access != "read_write" || slot.Ownership != "edit_target" {
			if len(actual) > 0 {
				return nil, fmt.Errorf("slot %s has changes but is not an edit target: %v", slotName, actual)
			}
			plans = append(plans, publishPlan{slotName: slotName, runtimePath: runtimePath, skipped: true})
			continue
		}
		changedFiles, err := changedFilesFor(slotName, actual)
		if err != nil {
			return nil, err
		}
		if len(changedFiles) == 0 {
			plans = append(plans, publishPlan{slotName: slotName, runtimePath: runtimePath, declared: changedFiles, noChanges: true})
			continue
		}
		plans = append(plans, publishPlan{slotName: slotName, runtimePath: runtimePath, declared: changedFiles})
	}
	return plans, nil
}

func executePublishPlans(prepared PreparedWorkspace, plans []publishPlan, commitMessage string) error {
	if commitMessage == "" {
		commitMessage = "A3 agent implementation update"
	}
	published := []publishPlan{}
	beforeHeads := map[string]string{}
	for _, plan := range plans {
		descriptor := prepared.SlotDescriptors[plan.slotName]
		descriptor["published_changed_files"] = plan.declared
		if plan.skipped {
			descriptor["publish_status"] = "skipped"
			descriptor["published"] = false
			descriptor["published_changed_files"] = []string{}
			continue
		}
		if plan.noChanges {
			descriptor["publish_status"] = "no_changes"
			descriptor["published"] = false
			continue
		}
		beforeHead, err := gitOutput(plan.runtimePath, "rev-parse", "HEAD")
		if err != nil {
			rollbackPublishedPlans(prepared, append(published, plan), beforeHeads)
			return err
		}
		beforeHeads[plan.slotName] = beforeHead
		if err := stageDeclaredPaths(plan.runtimePath, plan.declared); err != nil {
			rollbackPublishedPlans(prepared, append(published, plan), beforeHeads)
			return err
		}
		if err := runGit(plan.runtimePath, "-c", "user.name=A3 Agent", "-c", "user.email=a3-agent@example.invalid", "commit", "-m", commitMessage); err != nil {
			rollbackPublishedPlans(prepared, append(published, plan), beforeHeads)
			return err
		}
		afterHead, err := gitOutput(plan.runtimePath, "rev-parse", "HEAD")
		if err != nil {
			rollbackPublishedPlans(prepared, append(published, plan), beforeHeads)
			return err
		}
		descriptor["publish_status"] = "committed"
		descriptor["published"] = true
		descriptor["publish_before_head"] = beforeHead
		descriptor["publish_after_head"] = afterHead
		descriptor["resolved_head"] = afterHead
		published = append(published, plan)
	}
	return nil
}

func rollbackPublishedPlans(prepared PreparedWorkspace, plans []publishPlan, beforeHeads map[string]string) {
	for index := len(plans) - 1; index >= 0; index-- {
		plan := plans[index]
		descriptor := prepared.SlotDescriptors[plan.slotName]
		beforeHead := beforeHeads[plan.slotName]
		if beforeHead != "" {
			_ = runGit(plan.runtimePath, "reset", "--hard", beforeHead)
			_ = runGit(plan.runtimePath, "clean", "-fd", "--", ".", ":(exclude).a3")
			descriptor["resolved_head"] = beforeHead
		}
		clearPublishEvidence(descriptor)
	}
}

func clearPublishEvidence(descriptor map[string]any) {
	delete(descriptor, "publish_status")
	delete(descriptor, "published")
	delete(descriptor, "publish_before_head")
	delete(descriptor, "publish_after_head")
	delete(descriptor, "published_changed_files")
}

func declaredChangedFilesBySlot(workerProtocolResult map[string]any) (map[string][]string, error) {
	raw, ok := workerProtocolResult["changed_files"]
	if !ok || raw == nil {
		return map[string][]string{}, nil
	}
	rawMap, ok := raw.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("worker result changed_files must be an object")
	}
	result := map[string][]string{}
	for slotName, value := range rawMap {
		rawList, ok := value.([]any)
		if !ok {
			return nil, fmt.Errorf("worker result changed_files.%s must be an array", slotName)
		}
		paths := make([]string, 0, len(rawList))
		for _, rawPath := range rawList {
			path, ok := rawPath.(string)
			if !ok || path == "" {
				return nil, fmt.Errorf("worker result changed_files.%s entries must be non-empty strings", slotName)
			}
			paths = append(paths, path)
		}
		result[slotName] = normalizePathList(paths)
	}
	return result, nil
}

func normalizePathList(paths []string) []string {
	normalized := make([]string, 0, len(paths))
	for _, path := range paths {
		if path == "" {
			continue
		}
		normalized = append(normalized, filepath.Clean(path))
	}
	sort.Strings(normalized)
	return uniqueStrings(normalized)
}

func sameStrings(left, right []string) bool {
	left = normalizePathList(left)
	right = normalizePathList(right)
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func stageDeclaredPaths(root string, paths []string) error {
	args := append([]string{"add", "--"}, paths...)
	return runGit(root, args...)
}

func gitChangedPaths(root string) ([]string, error) {
	out, err := gitOutput(root, "status", "--porcelain", "--untracked-files=all", "--", ".", ":(exclude).a3")
	if err != nil {
		return nil, err
	}
	paths := []string{}
	for _, line := range strings.FieldsFunc(out, func(char rune) bool { return char == '\n' || char == '\r' }) {
		if len(line) < 4 {
			continue
		}
		path := line[3:]
		if path == "" {
			continue
		}
		if _, after, found := strings.Cut(path, " -> "); found {
			path = after
		}
		paths = append(paths, path)
	}
	sort.Strings(paths)
	return uniqueStrings(paths), nil
}

func uniqueStrings(values []string) []string {
	if len(values) == 0 {
		return values
	}
	unique := values[:1]
	for _, value := range values[1:] {
		if value != unique[len(unique)-1] {
			unique = append(unique, value)
		}
	}
	return unique
}

func (m WorkspaceMaterializer) workspaceRoot(workspaceID string) (string, error) {
	if m.WorkspaceRoot == "" {
		return "", fmt.Errorf("workspace root is required")
	}
	if workspaceID == "" {
		return "", fmt.Errorf("workspace id is required")
	}
	return filepath.Abs(filepath.Join(m.WorkspaceRoot, safeID(workspaceID)))
}

func (m WorkspaceMaterializer) sourceRoot(alias string) (string, error) {
	if alias == "" {
		return "", fmt.Errorf("source alias is required")
	}
	path := m.SourceAliases[alias]
	if path == "" {
		return "", fmt.Errorf("source alias is not configured: %s", alias)
	}
	return filepath.Abs(path)
}

func (m WorkspaceMaterializer) materializeSlot(sourceRoot, slotPath string, slot WorkspaceSlotRequest) (map[string]any, error) {
	if dirty, err := gitDirty(sourceRoot); err != nil {
		return nil, err
	} else if dirty {
		return nil, fmt.Errorf("source alias %s is dirty before materialization", slot.Source.Alias)
	}
	if err := os.RemoveAll(slotPath); err != nil {
		return nil, err
	}
	branchName, err := branchNameForRef(slot.Ref)
	if err != nil {
		return nil, err
	}
	bootstrapHead, bootstrappedRef, bootstrappedBaseRef, err := ensureWorkspaceSlotRef(sourceRoot, slot.Ref, slot.BootstrapRef, slot.BootstrapBaseRef)
	if err != nil {
		return nil, err
	}
	if err := runGit(sourceRoot, "worktree", "add", "--force", slotPath, branchName); err != nil {
		_ = rollbackWorkspaceSlotRefs(sourceRoot, slot.Ref, slot.BootstrapRef, bootstrappedRef, bootstrappedBaseRef)
		return nil, err
	}
	head, err := gitOutput(slotPath, "rev-parse", "HEAD")
	if err != nil {
		_ = runGit(sourceRoot, "worktree", "remove", "--force", slotPath)
		_ = rollbackWorkspaceSlotRefs(sourceRoot, slot.Ref, slot.BootstrapRef, bootstrappedRef, bootstrappedBaseRef)
		return nil, err
	}
	actualRef, err := gitOutput(slotPath, "symbolic-ref", "--quiet", "HEAD")
	if err != nil {
		_ = runGit(sourceRoot, "worktree", "remove", "--force", slotPath)
		_ = rollbackWorkspaceSlotRefs(sourceRoot, slot.Ref, slot.BootstrapRef, bootstrappedRef, bootstrappedBaseRef)
		return nil, err
	}
	dirtyAfter, err := gitDirty(slotPath)
	if err != nil {
		_ = runGit(sourceRoot, "worktree", "remove", "--force", slotPath)
		_ = rollbackWorkspaceSlotRefs(sourceRoot, slot.Ref, slot.BootstrapRef, bootstrappedRef, bootstrappedBaseRef)
		return nil, err
	}
	descriptor := map[string]any{
		"runtime_path":  slotPath,
		"source_kind":   slot.Source.Kind,
		"source_alias":  slot.Source.Alias,
		"checkout":      slot.Checkout,
		"requested_ref": slot.Ref,
		"branch_ref":    actualRef,
		"resolved_head": head,
		"dirty_before":  false,
		"dirty_after":   dirtyAfter,
		"access":        slot.Access,
		"sync_class":    slot.SyncClass,
		"ownership":     slot.Ownership,
	}
	if slot.BootstrapRef != "" {
		descriptor["bootstrap_ref"] = slot.BootstrapRef
	}
	if slot.BootstrapBaseRef != "" {
		descriptor["bootstrap_base_ref"] = slot.BootstrapBaseRef
	}
	if bootstrappedRef {
		descriptor["bootstrapped_ref"] = true
		descriptor["bootstrap_head"] = bootstrapHead
	}
	if bootstrappedBaseRef {
		descriptor["bootstrapped_base_ref"] = true
	}
	return descriptor, nil
}

func ensureWorkspaceSlotRef(root, targetRef, bootstrapRef, bootstrapBaseRef string) (string, bool, bool, error) {
	if _, err := branchNameForRef(targetRef); err != nil {
		return "", false, false, err
	}
	head, err := gitOutput(root, "rev-parse", targetRef)
	if err == nil {
		return head, false, false, nil
	}
	if bootstrapRef == "" {
		return "", false, false, fmt.Errorf("workspace ref %s is missing and bootstrap_ref is not provided", targetRef)
	}
	if _, err := branchNameForRef(bootstrapRef); err != nil {
		return "", false, false, fmt.Errorf("unsupported workspace bootstrap ref %s: %w", bootstrapRef, err)
	}
	bootstrapHead, err := gitOutput(root, "rev-parse", bootstrapRef)
	if err != nil {
		if bootstrapBaseRef == "" {
			return "", false, false, err
		}
		if _, branchErr := branchNameForRef(bootstrapBaseRef); branchErr != nil {
			return "", false, false, fmt.Errorf("unsupported workspace bootstrap base ref %s: %w", bootstrapBaseRef, branchErr)
		}
		bootstrapHead, err = gitOutput(root, "rev-parse", bootstrapBaseRef)
		if err != nil {
			return "", false, false, err
		}
		if err := runGit(root, "update-ref", bootstrapRef, bootstrapHead); err != nil {
			return "", false, false, err
		}
		if err := runGit(root, "update-ref", targetRef, bootstrapHead); err != nil {
			return "", false, true, err
		}
		return bootstrapHead, true, true, nil
	}
	if err := runGit(root, "update-ref", targetRef, bootstrapHead); err != nil {
		return "", false, false, err
	}
	return bootstrapHead, true, false, nil
}

func rollbackWorkspaceSlotRefs(root, targetRef, bootstrapRef string, createdTargetRef, createdBootstrapRef bool) error {
	var rollbackErr error
	if createdTargetRef {
		rollbackErr = errors.Join(rollbackErr, runGit(root, "update-ref", "-d", targetRef))
	}
	if createdBootstrapRef && bootstrapRef != "" {
		rollbackErr = errors.Join(rollbackErr, runGit(root, "update-ref", "-d", bootstrapRef))
	}
	return rollbackErr
}

func branchNameForRef(ref string) (string, error) {
	const prefix = "refs/heads/"
	if !strings.HasPrefix(ref, prefix) || len(ref) == len(prefix) {
		return "", fmt.Errorf("expected refs/heads/*")
	}
	return strings.TrimPrefix(ref, prefix), nil
}

func gitPatch(root string) (string, error) {
	if err := runGit(root, "add", "-N", "--", ".", ":(exclude).a3"); err != nil {
		return "", err
	}
	cmd := exec.Command("git", "-C", root, "diff", "--binary", "HEAD", "--", ".", ":(exclude).a3")
	out, err := cmd.Output()
	if err != nil {
		return "", gitError([]string{"diff", "--binary", "HEAD", "--", ".", ":(exclude).a3"}, err)
	}
	return string(out), nil
}

func gitDirty(root string) (bool, error) {
	out, err := gitOutput(root, "status", "--porcelain", "--untracked-files=all")
	if err != nil {
		return false, err
	}
	return out != "", nil
}

func gitDirtyIgnoringMetadata(root string) (bool, error) {
	out, err := gitOutput(root, "status", "--porcelain", "--untracked-files=all", "--", ".", ":(exclude).a3")
	if err != nil {
		return false, err
	}
	return out != "", nil
}

func gitOutput(root string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	out, err := cmd.Output()
	if err != nil {
		return "", gitError(args, err)
	}
	return trimTrailingNewline(string(out)), nil
}

func runGit(root string, args ...string) error {
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("git %v failed: %w: %s", args, err, trimTrailingNewline(string(out)))
	}
	return nil
}

func gitError(args []string, err error) error {
	if exitErr, ok := err.(*exec.ExitError); ok {
		return fmt.Errorf("git %v failed: %w: %s", args, err, trimTrailingNewline(string(exitErr.Stderr)))
	}
	return fmt.Errorf("git %v failed: %w", args, err)
}

func slotDirectory(slotName string) string {
	switch slotName {
	case "repo_alpha":
		return "repo-alpha"
	case "repo_beta":
		return "repo-beta"
	default:
		return safeID(slotName)
	}
}

func writeWorkspaceMetadata(root string, request WorkspaceRequest) error {
	metadataDir := filepath.Join(root, ".a3")
	if err := os.MkdirAll(metadataDir, 0o755); err != nil {
		return err
	}
	requirements := []map[string]string{}
	slotNames := make([]string, 0, len(request.Slots))
	for slotName := range request.Slots {
		slotNames = append(slotNames, slotName)
	}
	sort.Strings(slotNames)
	for _, slotName := range slotNames {
		requirements = append(requirements, map[string]string{
			"repo_slot":  slotName,
			"sync_class": "copy",
		})
	}
	payload := map[string]any{
		"workspace_kind":    request.WorkspaceKind,
		"source_type":       "branch_head",
		"source_ref":        workspaceSourceRef(request),
		"slot_requirements": requirements,
	}
	return writeMetadataJSON(filepath.Join(metadataDir, "workspace.json"), payload)
}

func writeSlotMetadata(slotPath string, sourceRoot string, request WorkspaceRequest, slotName string, slot WorkspaceSlotRequest) error {
	metadataDir := filepath.Join(slotPath, ".a3")
	if err := os.MkdirAll(metadataDir, 0o755); err != nil {
		return err
	}
	payload := map[string]any{
		"workspace_kind":   request.WorkspaceKind,
		"repo_slot":        slotName,
		"repo_source_root": sourceRoot,
		"sync_class":       "copy",
		"source_type":      "branch_head",
		"source_ref":       slot.Ref,
		"access":           slot.Access,
		"ownership":        slot.Ownership,
	}
	if err := writeMetadataJSON(filepath.Join(metadataDir, "slot.json"), payload); err != nil {
		return err
	}
	return writeMetadataJSON(filepath.Join(metadataDir, "materialized.json"), map[string]any{
		"workspace_kind": request.WorkspaceKind,
		"source_type":    "branch_head",
		"source_ref":     slot.Ref,
	})
}

func workspaceSourceRef(request WorkspaceRequest) string {
	for _, slot := range request.Slots {
		return slot.Ref
	}
	return ""
}

func writeMetadataJSON(path string, payload map[string]any) error {
	content, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return err
	}
	content = append(content, '\n')
	return os.WriteFile(path, content, 0o644)
}

func trimTrailingNewline(value string) string {
	for len(value) > 0 && (value[len(value)-1] == '\n' || value[len(value)-1] == '\r') {
		value = value[:len(value)-1]
	}
	return value
}
