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

type WorkspaceCleanupResult struct {
	WorkspaceRoot    string
	RemovedWorktrees []string
	RemovedWorkspace bool
	DryRun           bool
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

type mergeRecoveryPlan struct {
	slotName     string
	slot         MergeRecoverySlotRequest
	descriptor   map[string]any
	changedFiles []string
}

type gitWorktreeEntry struct {
	path   string
	branch string
}

func (e mergeConflictError) Error() string {
	return e.err.Error()
}

func (e mergeConflictError) Unwrap() error {
	return e.err
}

func (m WorkspaceMaterializer) Prepare(request WorkspaceRequest) (PreparedWorkspace, error) {
	root, err := m.workspaceRootForRequest(request)
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
	return descriptor, ExecutionResult{Status: "succeeded", ExitCode: intPtr(0), CombinedLog: []byte("A2O agent merge completed\n")}
}

func (m WorkspaceMaterializer) RecoverMerge(request MergeRecoveryRequest) (WorkspaceDescriptor, ExecutionResult) {
	descriptor := WorkspaceDescriptor{
		WorkspaceKind:    "runtime_workspace",
		RuntimeProfile:   "",
		WorkspaceID:      request.WorkspaceID,
		SourceDescriptor: SourceDescriptor{WorkspaceKind: "runtime_workspace", SourceType: "branch_head"},
		SlotDescriptors:  map[string]map[string]any{},
	}
	if request.WorkspaceID == "" {
		return descriptor, failedMergeExecution(fmt.Errorf("merge recovery workspace_id is required"))
	}
	slotNames := make([]string, 0, len(request.Slots))
	for slotName := range request.Slots {
		slotNames = append(slotNames, slotName)
	}
	sort.Strings(slotNames)
	plans := make([]mergeRecoveryPlan, 0, len(slotNames))
	for _, slotName := range slotNames {
		slot := request.Slots[slotName]
		slotDescriptor := map[string]any{
			"runtime_path":         slot.RuntimePath,
			"merge_target_ref":     slot.TargetRef,
			"merge_source_ref":     slot.SourceRef,
			"merge_before_head":    slot.MergeBeforeHead,
			"source_head_commit":   slot.SourceHeadCommit,
			"conflict_files":       normalizePathList(slot.ConflictFiles),
			"merge_status":         "recovery_prepared",
			"project_repo_mutator": "a2o-agent",
		}
		descriptor.SlotDescriptors[slotName] = slotDescriptor
		plan, err := prepareMergeRecoverySlot(slotName, slot, slotDescriptor)
		if err != nil {
			return descriptor, failedMergeExecution(err)
		}
		plans = append(plans, plan)
	}
	if err := commitRecoveredMergePlans(plans); err != nil {
		return descriptor, failedMergeExecution(err)
	}
	return descriptor, ExecutionResult{Status: "succeeded", ExitCode: intPtr(0), CombinedLog: []byte("A2O agent merge recovery completed\n")}
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
		if dirtyFiles, err := gitDirtyFiles(sourceRoot); err != nil {
			rollbackMergePlans(plans)
			return nil, err
		} else if len(dirtyFiles) > 0 {
			rollbackMergePlans(plans)
			return nil, fmt.Errorf("source alias %s is dirty before merge: changed_files=%v", slot.Source.Alias, dirtyFiles)
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
			"project_repo_mutator": "a2o-agent",
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

func prepareMergeRecoverySlot(slotName string, slot MergeRecoverySlotRequest, descriptor map[string]any) (mergeRecoveryPlan, error) {
	plan := mergeRecoveryPlan{slotName: slotName, slot: slot, descriptor: descriptor}
	if strings.TrimSpace(slot.RuntimePath) == "" {
		descriptor["merge_status"] = "recovery_failed"
		return plan, fmt.Errorf("merge recovery runtime_path is required for %s", slotName)
	}
	conflictFiles := normalizePathList(slot.ConflictFiles)
	if len(conflictFiles) == 0 {
		descriptor["merge_status"] = "recovery_failed"
		return plan, fmt.Errorf("merge recovery conflict_files are required for %s", slotName)
	}
	head, err := gitOutput(slot.RuntimePath, "rev-parse", "HEAD")
	if err != nil {
		descriptor["merge_status"] = "recovery_failed"
		return plan, err
	}
	if slot.MergeBeforeHead != "" && head != slot.MergeBeforeHead {
		descriptor["merge_status"] = "recovery_failed"
		return plan, fmt.Errorf("merge recovery head mismatch for %s: got=%s want=%s", slotName, head, slot.MergeBeforeHead)
	}
	mergeHead, err := gitOutput(slot.RuntimePath, "rev-parse", "MERGE_HEAD")
	if err != nil {
		descriptor["merge_status"] = "recovery_failed"
		return plan, fmt.Errorf("merge recovery workspace is not in a merge state for %s: %w", slotName, err)
	}
	if slot.SourceHeadCommit != "" && mergeHead != slot.SourceHeadCommit {
		descriptor["merge_status"] = "recovery_failed"
		return plan, fmt.Errorf("merge recovery source head mismatch for %s: got=%s want=%s", slotName, mergeHead, slot.SourceHeadCommit)
	}
	markerResult, err := scanConflictMarkers(slot.RuntimePath, conflictFiles)
	descriptor["marker_scan_result"] = markerResult
	if err != nil {
		descriptor["merge_status"] = "recovery_failed"
		return plan, err
	}
	if unresolved := markerResult["unresolved_files"].([]string); len(unresolved) > 0 {
		descriptor["merge_status"] = "recovery_failed"
		return plan, fmt.Errorf("merge recovery conflict markers remain for %s: %v", slotName, unresolved)
	}
	if err := stageDeclaredPaths(slot.RuntimePath, conflictFiles); err != nil {
		descriptor["merge_status"] = "recovery_failed"
		return plan, err
	}
	unmergedFiles, err := gitUnmergedFiles(slot.RuntimePath)
	if err != nil {
		descriptor["merge_status"] = "recovery_failed"
		return plan, err
	}
	if len(unmergedFiles) > 0 {
		descriptor["merge_status"] = "recovery_failed"
		descriptor["conflict_statuses"] = unmergedStatuses(unmergedFiles)
		return plan, fmt.Errorf("merge recovery has unresolved index conflicts for %s: %v", slotName, unmergedPaths(unmergedFiles))
	}
	changedFiles, err := gitChangedPaths(slot.RuntimePath)
	if err != nil {
		descriptor["merge_status"] = "recovery_failed"
		return plan, err
	}
	if !pathsWithin(changedFiles, conflictFiles) {
		descriptor["merge_status"] = "recovery_failed"
		descriptor["changed_files"] = changedFiles
		return plan, fmt.Errorf("merge recovery changed files outside conflict set for %s: changed=%v allowed=%v", slotName, changedFiles, conflictFiles)
	}
	if len(changedFiles) == 0 {
		descriptor["merge_status"] = "recovery_failed"
		return plan, fmt.Errorf("merge recovery produced no changes for %s", slotName)
	}
	plan.changedFiles = changedFiles
	return plan, nil
}

func commitRecoveredMergePlans(plans []mergeRecoveryPlan) error {
	committed := []mergeRecoveryPlan{}
	for _, plan := range plans {
		message := strings.TrimSpace(plan.slot.CommitMessage)
		if message == "" {
			message = "A2O agent merge recovery"
		}
		if err := runGit(plan.slot.RuntimePath, "-c", "user.name=A3 Agent", "-c", "user.email=a2o-agent@example.invalid", "commit", "--no-gpg-sign", "--no-verify", "-m", message); err != nil {
			plan.descriptor["merge_status"] = "recovery_failed"
			return errors.Join(err, rollbackRecoveredMergePlans(committed))
		}
		afterHead, err := gitOutput(plan.slot.RuntimePath, "rev-parse", "HEAD")
		if err != nil {
			plan.descriptor["merge_status"] = "recovery_failed"
			return errors.Join(err, rollbackRecoveredMergePlans(append(committed, plan)))
		}
		plan.descriptor["merge_status"] = "recovered"
		plan.descriptor["resolved_conflict_files"] = normalizePathList(plan.slot.ConflictFiles)
		plan.descriptor["changed_files"] = plan.changedFiles
		plan.descriptor["publish_before_head"] = plan.slot.MergeBeforeHead
		plan.descriptor["publish_after_head"] = afterHead
		plan.descriptor["merge_after_head"] = afterHead
		plan.descriptor["resolved_head"] = afterHead
		committed = append(committed, plan)
	}
	return nil
}

func rollbackRecoveredMergePlans(plans []mergeRecoveryPlan) error {
	var rollbackErr error
	for index := len(plans) - 1; index >= 0; index-- {
		plan := plans[index]
		if plan.slot.MergeBeforeHead != "" {
			rollbackErr = errors.Join(rollbackErr, runGit(plan.slot.RuntimePath, "reset", "--hard", plan.slot.MergeBeforeHead))
			plan.descriptor["merge_status"] = "recovery_rolled_back"
			delete(plan.descriptor, "publish_after_head")
			delete(plan.descriptor, "merge_after_head")
			delete(plan.descriptor, "resolved_head")
		}
	}
	return rollbackErr
}

func scanConflictMarkers(root string, paths []string) (map[string]any, error) {
	unresolved := []string{}
	for _, path := range normalizePathList(paths) {
		if filepath.IsAbs(path) || strings.HasPrefix(path, ".."+string(filepath.Separator)) || path == ".." {
			return nil, fmt.Errorf("merge recovery conflict file path must be relative: %s", path)
		}
		data, err := os.ReadFile(filepath.Join(root, path))
		if err != nil {
			return nil, err
		}
		if containsConflictMarker(string(data)) {
			unresolved = append(unresolved, path)
		}
	}
	return map[string]any{
		"scanner":          "a2o-agent-conflict-marker-scan",
		"unresolved_files": unresolved,
	}, nil
}

func containsConflictMarker(content string) bool {
	for _, line := range strings.FieldsFunc(content, func(char rune) bool { return char == '\n' || char == '\r' }) {
		if strings.HasPrefix(line, "<<<<<<< ") || strings.HasPrefix(line, "=======") || strings.HasPrefix(line, ">>>>>>> ") {
			return true
		}
	}
	return false
}

func pathsWithin(changedFiles, allowedFiles []string) bool {
	allowed := map[string]bool{}
	for _, path := range normalizePathList(allowedFiles) {
		allowed[path] = true
	}
	for _, path := range normalizePathList(changedFiles) {
		if !allowed[path] {
			return false
		}
	}
	return true
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
	return ExecutionResult{Status: "failed", ExitCode: intPtr(1), CombinedLog: []byte("A2O agent merge failed: " + err.Error() + "\n")}
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

func (m WorkspaceMaterializer) CleanupDescriptor(descriptor WorkspaceDescriptor, dryRun bool) (WorkspaceCleanupResult, error) {
	root, err := m.workspaceRootForDescriptor(descriptor)
	if err != nil {
		return WorkspaceCleanupResult{}, err
	}
	result := WorkspaceCleanupResult{
		WorkspaceRoot:    root,
		RemovedWorktrees: []string{},
		DryRun:           dryRun,
	}

	slotNames := make([]string, 0, len(descriptor.SlotDescriptors))
	for slotName := range descriptor.SlotDescriptors {
		slotNames = append(slotNames, slotName)
	}
	sort.Strings(slotNames)
	for _, slotName := range slotNames {
		slotDescriptor := descriptor.SlotDescriptors[slotName]
		runtimePath, ok := slotDescriptor["runtime_path"].(string)
		if !ok || runtimePath == "" {
			return result, fmt.Errorf("slot descriptor runtime_path is required for %s", slotName)
		}
		absRuntimePath, err := filepath.Abs(runtimePath)
		if err != nil {
			return result, fmt.Errorf("resolve runtime_path for %s: %w", slotName, err)
		}
		if !pathInside(root, absRuntimePath) {
			return result, fmt.Errorf("slot %s runtime_path is outside workspace root: %s", slotName, runtimePath)
		}
		sourceRoot, err := repoSourceRootFromSlotMetadata(absRuntimePath)
		if err != nil {
			return result, fmt.Errorf("slot %s cleanup metadata: %w", slotName, err)
		}
		if !dryRun {
			if err := runGit(sourceRoot, "worktree", "remove", "--force", absRuntimePath); err != nil {
				return result, err
			}
		}
		result.RemovedWorktrees = append(result.RemovedWorktrees, absRuntimePath)
	}
	if !dryRun {
		if err := os.RemoveAll(root); err != nil {
			return result, err
		}
	}
	result.RemovedWorkspace = true
	return result, nil
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
		commitMessage = "A2O agent implementation update"
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
		if err := runGit(plan.runtimePath, "-c", "user.name=A3 Agent", "-c", "user.email=a2o-agent@example.invalid", "commit", "--no-gpg-sign", "--no-verify", "-m", commitMessage); err != nil {
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

func (m WorkspaceMaterializer) workspaceRootForRequest(request WorkspaceRequest) (string, error) {
	if request.WorkspaceID == "" {
		return "", fmt.Errorf("workspace id is required")
	}
	if request.Topology == nil {
		return m.workspaceRoot(request.WorkspaceID)
	}
	if request.Topology.Kind != "parent_child" {
		return "", fmt.Errorf("unsupported workspace topology kind: %s", request.Topology.Kind)
	}
	parentRoot, err := m.workspaceRoot(request.Topology.ParentWorkspaceID)
	if err != nil {
		return "", err
	}
	relativePath, err := safeRelativePath(request.Topology.RelativePath)
	if err != nil {
		return "", err
	}
	return filepath.Abs(filepath.Join(parentRoot, relativePath))
}

func (m WorkspaceMaterializer) workspaceRootForDescriptor(descriptor WorkspaceDescriptor) (string, error) {
	if descriptor.WorkspaceID == "" {
		return "", fmt.Errorf("workspace id is required")
	}
	if descriptor.Topology == nil {
		return m.workspaceRoot(descriptor.WorkspaceID)
	}
	if descriptor.Topology.Kind != "parent_child" {
		return "", fmt.Errorf("unsupported workspace topology kind: %s", descriptor.Topology.Kind)
	}
	parentRoot, err := m.workspaceRoot(descriptor.Topology.ParentWorkspaceID)
	if err != nil {
		return "", err
	}
	relativePath, err := safeRelativePath(descriptor.Topology.RelativePath)
	if err != nil {
		return "", err
	}
	return filepath.Abs(filepath.Join(parentRoot, relativePath))
}

func safeRelativePath(value string) (string, error) {
	if value == "" {
		return "", fmt.Errorf("workspace topology relative_path is required")
	}
	if filepath.IsAbs(value) {
		return "", fmt.Errorf("workspace topology relative_path must be relative: %s", value)
	}
	clean := filepath.Clean(value)
	if clean == "." || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("workspace topology relative_path must stay under parent workspace: %s", value)
	}
	return clean, nil
}

func pathInside(root string, path string) bool {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	return rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

func repoSourceRootFromSlotMetadata(slotPath string) (string, error) {
	content, err := os.ReadFile(slotMetadataPath(slotPath))
	if err != nil {
		return "", err
	}
	var payload map[string]any
	if err := json.Unmarshal(content, &payload); err != nil {
		return "", err
	}
	sourceRoot, ok := payload["repo_source_root"].(string)
	if !ok || sourceRoot == "" {
		return "", fmt.Errorf("repo_source_root is required")
	}
	return sourceRoot, nil
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
	if dirtyFiles, err := gitDirtyFiles(sourceRoot); err != nil {
		return nil, err
	} else if len(dirtyFiles) > 0 {
		return nil, fmt.Errorf("source alias %s is dirty before materialization: changed_files=%v", slot.Source.Alias, dirtyFiles)
	}
	if err := os.RemoveAll(slotPath); err != nil {
		return nil, err
	}
	branchName, err := branchNameForRef(slot.Ref)
	if err != nil {
		return nil, err
	}
	if err := m.removeStaleWorkspaceWorktrees(sourceRoot, slotPath, branchName); err != nil {
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

func (m WorkspaceMaterializer) removeStaleWorkspaceWorktrees(sourceRoot, slotPath, branchName string) error {
	if err := runGit(sourceRoot, "worktree", "prune"); err != nil {
		return err
	}
	entries, err := gitWorktreeEntries(sourceRoot)
	if err != nil {
		return err
	}
	absSlotPath, err := filepath.Abs(slotPath)
	if err != nil {
		return err
	}
	absWorkspaceRoot, err := filepath.Abs(m.WorkspaceRoot)
	if err != nil {
		return err
	}
	branchRef := "refs/heads/" + branchName
	var cleanupErr error
	for _, entry := range entries {
		absEntryPath, err := filepath.Abs(entry.path)
		if err != nil {
			cleanupErr = errors.Join(cleanupErr, err)
			continue
		}
		reusesSlotPath := filepath.Clean(absEntryPath) == filepath.Clean(absSlotPath)
		reusesBranchInA2OWorkspace := entry.branch == branchRef && pathInside(absWorkspaceRoot, absEntryPath)
		if !reusesSlotPath && !reusesBranchInA2OWorkspace {
			continue
		}
		cleanupErr = errors.Join(cleanupErr, runGit(sourceRoot, "worktree", "remove", "--force", absEntryPath))
	}
	if cleanupErr != nil {
		return cleanupErr
	}
	return runGit(sourceRoot, "worktree", "prune")
}

func gitWorktreeEntries(sourceRoot string) ([]gitWorktreeEntry, error) {
	out, err := gitOutput(sourceRoot, "worktree", "list", "--porcelain")
	if err != nil {
		return nil, err
	}
	entries := []gitWorktreeEntry{}
	current := gitWorktreeEntry{}
	appendCurrent := func() {
		if current.path == "" {
			return
		}
		entries = append(entries, current)
		current = gitWorktreeEntry{}
	}
	for _, line := range strings.Split(out, "\n") {
		switch {
		case line == "":
			appendCurrent()
		case strings.HasPrefix(line, "worktree "):
			appendCurrent()
			current.path = strings.TrimSpace(strings.TrimPrefix(line, "worktree "))
		case strings.HasPrefix(line, "branch "):
			current.branch = strings.TrimSpace(strings.TrimPrefix(line, "branch "))
		}
	}
	appendCurrent()
	return entries, nil
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
	files, err := gitDirtyFiles(root)
	if err != nil {
		return false, err
	}
	return len(files) > 0, nil
}

func gitDirtyFiles(root string) ([]string, error) {
	out, err := gitOutput(root, "status", "--porcelain", "--untracked-files=all")
	if err != nil {
		return nil, err
	}
	if out == "" {
		return nil, nil
	}
	files := []string{}
	for _, line := range strings.Split(out, "\n") {
		if len(line) <= 3 {
			continue
		}
		files = append(files, strings.TrimSpace(line[3:]))
	}
	sort.Strings(files)
	return files, nil
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
	return safeID(slotName)
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
	if request.Topology != nil {
		payload["topology"] = request.Topology
	}
	return writeMetadataJSON(filepath.Join(metadataDir, "workspace.json"), payload)
}

func writeSlotMetadata(slotPath string, sourceRoot string, request WorkspaceRequest, slotName string, slot WorkspaceSlotRequest) error {
	metadataDir := slotMetadataDir(slotPath)
	if err := os.MkdirAll(metadataDir, 0o755); err != nil {
		return err
	}
	payload := map[string]any{
		"workspace_kind":   request.WorkspaceKind,
		"repo_slot":        slotName,
		"slot_path":        slotPath,
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

func slotMetadataDir(slotPath string) string {
	return filepath.Join(filepath.Dir(slotPath), ".a2o", "slots", filepath.Base(slotPath))
}

func slotMetadataPath(slotPath string) string {
	return filepath.Join(slotMetadataDir(slotPath), "slot.json")
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
