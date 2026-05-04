package agent

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestWorkspaceMaterializerPreparesAndCleansWorktreeSlots(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "sample-catalog-service")
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"sample-catalog-service": sourceRoot,
		},
	}

	prepared, err := materializer.Prepare(testWorkspaceRequest("sample-catalog-service"))
	if err != nil {
		t.Fatal(err)
	}
	slotPath := filepath.Join(prepared.Root, "repo_alpha")
	if _, err := os.Stat(filepath.Join(slotPath, "README.md")); err != nil {
		t.Fatal(err)
	}
	descriptor := prepared.SlotDescriptors["repo_alpha"]
	if descriptor["source_alias"] != "sample-catalog-service" {
		t.Fatalf("unexpected descriptor: %#v", descriptor)
	}
	if descriptor["branch_ref"] != "refs/heads/a3/work/Sample-42" {
		t.Fatalf("unexpected branch descriptor: %#v", descriptor)
	}
	if descriptor["dirty_before"] != false || descriptor["dirty_after"] != false {
		t.Fatalf("unexpected dirty descriptor: %#v", descriptor)
	}
	workspaceMetadata := readJSON(t, filepath.Join(prepared.Root, ".a2o", "workspace.json"))
	if workspaceMetadata["workspace_kind"] != "ticket_workspace" || workspaceMetadata["source_ref"] != "refs/heads/a3/work/Sample-42" {
		t.Fatalf("unexpected workspace metadata: %#v", workspaceMetadata)
	}
	if _, err := os.Stat(filepath.Join(slotPath, ".a3")); !os.IsNotExist(err) {
		t.Fatalf("slot metadata must not be written inside the repo slot, stat err=%v", err)
	}
	slotMetadata := readJSON(t, filepath.Join(prepared.Root, ".a2o", "slots", "repo_alpha", "slot.json"))
	if slotMetadata["repo_source_root"] != sourceRoot || slotMetadata["repo_slot"] != "repo_alpha" {
		t.Fatalf("unexpected slot metadata: %#v", slotMetadata)
	}
	if slotMetadata["slot_path"] != slotPath {
		t.Fatalf("unexpected slot path metadata: %#v", slotMetadata)
	}
	if status := git(t, slotPath, "status", "--porcelain", "--untracked-files=all"); strings.Contains(status, ".a3") || strings.Contains(status, ".a2o") {
		t.Fatalf("agent metadata should not appear in slot git status: %s", status)
	}
	if out := git(t, sourceRoot, "worktree", "list", "--porcelain"); !contains(out, slotPath) {
		t.Fatalf("worktree was not registered: %s", out)
	}

	if err := materializer.Cleanup(prepared); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(slotPath); !os.IsNotExist(err) {
		t.Fatalf("slot path still exists: %v", err)
	}
	if out := git(t, sourceRoot, "worktree", "list", "--porcelain"); contains(out, slotPath) {
		t.Fatalf("worktree was not removed: %s", out)
	}
}

func TestWorkspaceMaterializerRepairsStaleWorktreeBeforePreparingSlot(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "sample-catalog-service")
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"sample-catalog-service": sourceRoot,
		},
	}
	request := testWorkspaceRequest("sample-catalog-service")

	stale, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	staleSlotPath := filepath.Join(stale.Root, "repo_alpha")
	if out := git(t, sourceRoot, "worktree", "list", "--porcelain"); !contains(out, staleSlotPath) {
		t.Fatalf("stale worktree was not registered: %s", out)
	}

	prepared, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	if prepared.Root != stale.Root {
		t.Fatalf("unexpected workspace root: got=%s want=%s", prepared.Root, stale.Root)
	}
	if out := git(t, sourceRoot, "worktree", "list", "--porcelain"); strings.Count(out, staleSlotPath) != 1 {
		t.Fatalf("expected one repaired worktree registration for %s, got:\n%s", staleSlotPath, out)
	}
	if err := materializer.Cleanup(prepared); err != nil {
		t.Fatal(err)
	}
}

func TestWorkspaceMaterializerRemovesUntrackedFilesBeforeReusingSlot(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "sample-catalog-service")
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"sample-catalog-service": sourceRoot,
		},
	}
	request := testWorkspaceRequest("sample-catalog-service")

	stale, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	staleSlotPath := filepath.Join(stale.Root, "repo_alpha")
	staleDir := filepath.Join(staleSlotPath, "port", "in", "feature-A")
	if err := os.MkdirAll(staleDir, 0o755); err != nil {
		t.Fatal(err)
	}
	staleFile := filepath.Join(staleDir, "Client.java")
	if err := os.WriteFile(staleFile, []byte("stale\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if status := git(t, staleSlotPath, "status", "--porcelain", "--untracked-files=all"); !strings.Contains(status, "Client.java") {
		t.Fatalf("expected stale untracked file before reuse, got %s", status)
	}

	prepared, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	if prepared.Root != stale.Root {
		t.Fatalf("unexpected workspace root: got=%s want=%s", prepared.Root, stale.Root)
	}
	slotPath := filepath.Join(prepared.Root, "repo_alpha")
	if _, err := os.Stat(staleFile); !os.IsNotExist(err) {
		t.Fatalf("stale untracked file survived workspace reuse: %v", err)
	}
	if status := git(t, slotPath, "status", "--porcelain", "--untracked-files=all"); status != "" {
		t.Fatalf("reused worktree should be clean, got %s", status)
	}
	if err := materializer.Cleanup(prepared); err != nil {
		t.Fatal(err)
	}
}

func TestWorkspaceMaterializerUsesParentChildTopologyRoot(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "sample-catalog-service")
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"sample-catalog-service": sourceRoot,
		},
	}
	request := testWorkspaceRequest("sample-catalog-service")
	request.WorkspaceID = "Sample-134-children-Sample-135-implementation-run-implementation"
	request.Topology = &WorkspaceTopology{
		Kind:              "parent_child",
		ParentRef:         "Sample#134",
		ChildRef:          "Sample#135",
		ParentWorkspaceID: "Sample-134-parent",
		RelativePath:      "children/Sample-135/ticket_workspace",
	}

	prepared, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	expectedRoot := filepath.Join(tmp, "agent-workspaces", "Sample-134-parent", "children", "Sample-135", "ticket_workspace")
	if prepared.Root != expectedRoot {
		t.Fatalf("unexpected topology root: got=%s want=%s", prepared.Root, expectedRoot)
	}
	workspaceMetadata := readJSON(t, filepath.Join(prepared.Root, ".a2o", "workspace.json"))
	topology, ok := workspaceMetadata["topology"].(map[string]any)
	if !ok || topology["parent_workspace_id"] != "Sample-134-parent" || topology["relative_path"] != "children/Sample-135/ticket_workspace" {
		t.Fatalf("unexpected topology metadata: %#v", workspaceMetadata)
	}
	if err := materializer.Cleanup(prepared); err != nil {
		t.Fatal(err)
	}
}

func TestWorkspaceMaterializerCleansDescriptorWithParentChildTopology(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "sample-catalog-service")
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"sample-catalog-service": sourceRoot,
		},
	}
	request := testWorkspaceRequest("sample-catalog-service")
	request.WorkspaceID = "Sample-134-children-Sample-135-implementation-run-implementation"
	request.Topology = &WorkspaceTopology{
		Kind:              "parent_child",
		ParentRef:         "Sample#134",
		ChildRef:          "Sample#135",
		ParentWorkspaceID: "Sample-134-parent",
		RelativePath:      "children/Sample-135/ticket_workspace",
	}
	prepared, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	siblingPath := filepath.Join(tmp, "agent-workspaces", "Sample-999-parent", "children", "Sample-135", "ticket_workspace")
	if err := os.MkdirAll(siblingPath, 0o755); err != nil {
		t.Fatal(err)
	}
	descriptor := WorkspaceDescriptor{
		WorkspaceKind:    request.WorkspaceKind,
		RuntimeProfile:   "host-local",
		WorkspaceID:      request.WorkspaceID,
		SourceDescriptor: SourceDescriptor{WorkspaceKind: request.WorkspaceKind, SourceType: "branch_head"},
		SlotDescriptors:  prepared.SlotDescriptors,
		Topology:         request.Topology,
	}

	result, err := materializer.CleanupDescriptor(descriptor, false)
	if err != nil {
		t.Fatal(err)
	}
	if result.WorkspaceRoot != prepared.Root || !result.RemovedWorkspace || len(result.RemovedWorktrees) != 1 {
		t.Fatalf("unexpected cleanup result: %#v", result)
	}
	if _, err := os.Stat(prepared.Root); !os.IsNotExist(err) {
		t.Fatalf("workspace still exists: %v", err)
	}
	if _, err := os.Stat(siblingPath); err != nil {
		t.Fatalf("sibling workspace was removed: %v", err)
	}
	if out := git(t, sourceRoot, "worktree", "list", "--porcelain"); contains(out, result.RemovedWorktrees[0]) {
		t.Fatalf("worktree was not removed: %s", out)
	}
}

func TestWorkspaceMaterializerRejectsDescriptorSlotOutsideTopologyRoot(t *testing.T) {
	tmp := t.TempDir()
	materializer := WorkspaceMaterializer{WorkspaceRoot: filepath.Join(tmp, "agent-workspaces")}
	descriptor := WorkspaceDescriptor{
		WorkspaceKind:    "ticket_workspace",
		RuntimeProfile:   "host-local",
		WorkspaceID:      "Sample-134-children-Sample-135-implementation-run-implementation",
		SourceDescriptor: SourceDescriptor{WorkspaceKind: "ticket_workspace", SourceType: "branch_head"},
		SlotDescriptors: map[string]map[string]any{
			"repo_alpha": {
				"runtime_path": filepath.Join(tmp, "agent-workspaces", "Sample-999-parent", "children", "Sample-135", "ticket_workspace", "repo_alpha"),
			},
		},
		Topology: &WorkspaceTopology{
			Kind:              "parent_child",
			ParentRef:         "Sample#134",
			ChildRef:          "Sample#135",
			ParentWorkspaceID: "Sample-134-parent",
			RelativePath:      "children/Sample-135/ticket_workspace",
		},
	}

	if _, err := materializer.CleanupDescriptor(descriptor, true); err == nil || !strings.Contains(err.Error(), "outside workspace root") {
		t.Fatalf("expected outside root rejection, got %v", err)
	}
}

func TestWorkspaceMaterializerRejectsUnsafeParentChildTopologyPath(t *testing.T) {
	request := testWorkspaceRequest("sample-catalog-service")
	request.Topology = &WorkspaceTopology{
		Kind:              "parent_child",
		ParentWorkspaceID: "Sample-134-parent",
		RelativePath:      "../escape",
	}
	materializer := WorkspaceMaterializer{WorkspaceRoot: t.TempDir()}

	if _, err := materializer.Prepare(request); err == nil || !strings.Contains(err.Error(), "relative_path must stay under parent workspace") {
		t.Fatalf("expected unsafe relative_path failure, got %v", err)
	}
}

func readJSON(t *testing.T, path string) map[string]any {
	t.Helper()
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var payload map[string]any
	if err := json.Unmarshal(content, &payload); err != nil {
		t.Fatal(err)
	}
	return payload
}

func TestWorkspaceMaterializerFailsBeforeCommandForDirtySource(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "sample-catalog-service")
	if err := os.WriteFile(filepath.Join(sourceRoot, "dirty.txt"), []byte("dirty\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"sample-catalog-service": sourceRoot,
		},
	}

	if _, err := materializer.Prepare(testWorkspaceRequest("sample-catalog-service")); err == nil {
		t.Fatal("expected dirty source failure")
	} else if !strings.Contains(err.Error(), "dirty.txt") {
		t.Fatalf("expected dirty source failure to include changed file, got %v", err)
	}
}

func TestWorkspaceMaterializerRejectsMissingSlotMetadata(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "sample-catalog-service")
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"sample-catalog-service": sourceRoot,
		},
	}
	request := testWorkspaceRequest("sample-catalog-service")
	slot := request.Slots["repo_alpha"]
	slot.SyncClass = ""
	request.Slots["repo_alpha"] = slot

	if _, err := materializer.Prepare(request); err == nil || !strings.Contains(err.Error(), "unsupported sync_class") {
		t.Fatalf("expected unsupported sync_class failure, got %v", err)
	}
}

func TestWorkspaceMaterializerRejectsNonBranchRefs(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "sample-catalog-service")
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"sample-catalog-service": sourceRoot,
		},
	}
	request := testWorkspaceRequest("sample-catalog-service")
	slot := request.Slots["repo_alpha"]
	slot.Ref = "HEAD"
	request.Slots["repo_alpha"] = slot

	if _, err := materializer.Prepare(request); err == nil || !strings.Contains(err.Error(), "unsupported branch ref") {
		t.Fatalf("expected unsupported branch ref failure, got %v", err)
	}
}

func TestWorkspaceMaterializerBootstrapsMissingWorktreeBranchAtMaterialization(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "sample-catalog-service")
	git(t, sourceRoot, "branch", "feature/prototype", "HEAD")
	liveHead := strings.TrimSpace(git(t, sourceRoot, "rev-parse", "HEAD"))
	request := testWorkspaceRequest("sample-catalog-service")
	slot := request.Slots["repo_alpha"]
	slot.Ref = "refs/heads/a3/work/Sample-99"
	slot.BootstrapRef = "refs/heads/feature/prototype"
	request.Slots["repo_alpha"] = slot
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"sample-catalog-service": sourceRoot,
		},
	}

	prepared, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	descriptor := prepared.SlotDescriptors["repo_alpha"]
	if descriptor["bootstrapped_ref"] != true || descriptor["bootstrap_head"] != liveHead {
		t.Fatalf("unexpected bootstrap descriptor: %#v", descriptor)
	}
	if head := strings.TrimSpace(git(t, sourceRoot, "rev-parse", "refs/heads/a3/work/Sample-99")); head != liveHead {
		t.Fatalf("branch was not bootstrapped from live head: got=%s want=%s", head, liveHead)
	}
	if err := materializer.Cleanup(prepared); err != nil {
		t.Fatal(err)
	}
}

func TestWorkspaceMaterializerRequiresBootstrapForMissingWorktreeBranch(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "sample-catalog-service")
	request := testWorkspaceRequest("sample-catalog-service")
	slot := request.Slots["repo_alpha"]
	slot.Ref = "refs/heads/a3/work/Sample-99"
	request.Slots["repo_alpha"] = slot
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"sample-catalog-service": sourceRoot,
		},
	}

	if _, err := materializer.Prepare(request); err == nil || !strings.Contains(err.Error(), "bootstrap_ref is not provided") {
		t.Fatalf("expected missing bootstrap_ref failure, got %v", err)
	}
}

func TestWorkspaceMaterializerBootstrapsMissingParentThenChildBranch(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "sample-catalog-service")
	git(t, sourceRoot, "branch", "feature/prototype", "HEAD")
	liveHead := strings.TrimSpace(git(t, sourceRoot, "rev-parse", "HEAD"))
	request := testWorkspaceRequest("sample-catalog-service")
	slot := request.Slots["repo_alpha"]
	slot.Ref = "refs/heads/a3/work/Sample-204"
	slot.BootstrapRef = "refs/heads/a3/parent/Sample-203"
	slot.BootstrapBaseRef = "refs/heads/feature/prototype"
	request.Slots["repo_alpha"] = slot
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"sample-catalog-service": sourceRoot,
		},
	}

	prepared, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	descriptor := prepared.SlotDescriptors["repo_alpha"]
	if descriptor["bootstrapped_ref"] != true || descriptor["bootstrapped_base_ref"] != true {
		t.Fatalf("unexpected chained bootstrap descriptor: %#v", descriptor)
	}
	if parentHead := strings.TrimSpace(git(t, sourceRoot, "rev-parse", "refs/heads/a3/parent/Sample-203")); parentHead != liveHead {
		t.Fatalf("parent branch was not bootstrapped from live head: got=%s want=%s", parentHead, liveHead)
	}
	if childHead := strings.TrimSpace(git(t, sourceRoot, "rev-parse", "refs/heads/a3/work/Sample-204")); childHead != liveHead {
		t.Fatalf("child branch was not bootstrapped from parent head: got=%s want=%s", childHead, liveHead)
	}
	if err := materializer.Cleanup(prepared); err != nil {
		t.Fatal(err)
	}
}

func TestPublishWorkspaceChangesValidatesAllSlotsBeforeCommitting(t *testing.T) {
	tmp := t.TempDir()
	alphaRoot := createGitSource(t, tmp, "repo-alpha")
	betaRoot := createGitSource(t, tmp, "repo-beta")
	request := testWorkspaceRequest("repo-alpha")
	request.Slots["repo_beta"] = WorkspaceSlotRequest{
		Source: WorkspaceSourceRequest{
			Kind:  "local_git",
			Alias: "repo-beta",
		},
		Ref:       "refs/heads/a3/work/Sample-42",
		Checkout:  "worktree_branch",
		Access:    "read_write",
		SyncClass: "eager",
		Ownership: "edit_target",
		Required:  true,
	}
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"repo-alpha": alphaRoot,
			"repo-beta":  betaRoot,
		},
	}
	prepared, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	alphaHead := git(t, alphaRoot, "rev-parse", "a3/work/Sample-42")
	if err := os.WriteFile(filepath.Join(prepared.Root, "repo_alpha", "alpha.txt"), []byte("alpha\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(prepared.Root, "repo_beta", "beta.txt"), []byte("beta\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	err = PublishWorkspaceChanges(prepared, request, map[string]any{
		"success": true,
		"changed_files": map[string]any{
			"repo_alpha": []any{"alpha.txt"},
			"repo_beta":  []any{},
		},
	}, true)

	if err == nil || !strings.Contains(err.Error(), "repo_beta changed files do not match worker result") {
		t.Fatalf("expected repo_beta changed files mismatch, got %v", err)
	}
	if head := git(t, alphaRoot, "rev-parse", "a3/work/Sample-42"); head != alphaHead {
		t.Fatalf("repo_alpha branch advanced before all slots validated: before=%s after=%s", alphaHead, head)
	}
}

func TestPublishWorkspaceChangesCommitsAllEditTargetChangesOnCommandSuccess(t *testing.T) {
	tmp := t.TempDir()
	alphaRoot := createGitSource(t, tmp, "repo-alpha")
	betaRoot := createGitSource(t, tmp, "repo-beta")
	request := testWorkspaceRequest("repo-alpha")
	request.PublishPolicy = &WorkspacePublishPolicy{
		Mode:          "commit_all_edit_target_changes_on_success",
		CommitMessage: "A3 remediation update for Sample#42",
	}
	request.Slots["repo_beta"] = WorkspaceSlotRequest{
		Source:    WorkspaceSourceRequest{Kind: "local_git", Alias: "repo-beta"},
		Ref:       "refs/heads/a3/work/Sample-42",
		Checkout:  "worktree_branch",
		Access:    "read_only",
		SyncClass: "lazy_but_guaranteed",
		Ownership: "support",
		Required:  true,
	}
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"repo-alpha": alphaRoot,
			"repo-beta":  betaRoot,
		},
	}
	prepared, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(prepared.Root, "repo_alpha", "formatted.txt"), []byte("formatted\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	err = PublishWorkspaceChanges(prepared, request, nil, true)

	if err != nil {
		t.Fatal(err)
	}
	alphaSlot := prepared.SlotDescriptors["repo_alpha"]
	if alphaSlot["publish_status"] != "committed" || alphaSlot["published"] != true {
		t.Fatalf("expected remediation commit evidence: %#v", alphaSlot)
	}
	if head := trimTrailingNewline(git(t, alphaRoot, "rev-parse", "a3/work/Sample-42")); head != alphaSlot["publish_after_head"] {
		t.Fatalf("source branch was not advanced by remediation: head=%s slot=%#v", head, alphaSlot)
	}
	if betaSlot := prepared.SlotDescriptors["repo_beta"]; betaSlot["publish_status"] != "skipped" || betaSlot["published"] != false {
		t.Fatalf("support slot should be skipped: %#v", betaSlot)
	}
}

func TestPublishWorkspaceChangesCommitsAllEditTargetChangesOnWorkerSuccess(t *testing.T) {
	tmp := t.TempDir()
	alphaRoot := createGitSource(t, tmp, "repo-alpha")
	request := testWorkspaceRequest("repo-alpha")
	request.PublishPolicy = &WorkspacePublishPolicy{
		Mode:          "commit_all_edit_target_changes_on_worker_success",
		CommitMessage: "A3 implementation update for Sample#42",
	}
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{"repo-alpha": alphaRoot},
	}
	prepared, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(prepared.Root, "repo_alpha", "declared.txt"), []byte("declared\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(prepared.Root, "repo_alpha", "generated.txt"), []byte("generated\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	err = PublishWorkspaceChanges(prepared, request, map[string]any{
		"success": true,
		"changed_files": map[string]any{
			"repo_alpha": []any{"declared.txt"},
		},
	}, true)

	if err != nil {
		t.Fatal(err)
	}
	alphaSlot := prepared.SlotDescriptors["repo_alpha"]
	if alphaSlot["publish_status"] != "committed" || alphaSlot["published"] != true {
		t.Fatalf("expected implementation commit evidence: %#v", alphaSlot)
	}
	published := stringSlice(alphaSlot["published_changed_files"])
	if join(published) != "declared.txt,generated.txt" {
		t.Fatalf("expected actual edit-target changes to be published, got %#v", published)
	}
	commitFiles := git(t, alphaRoot, "show", "--name-only", "--format=", "a3/work/Sample-42")
	if !strings.Contains(commitFiles, "declared.txt") || !strings.Contains(commitFiles, "generated.txt") {
		t.Fatalf("implementation commit did not include actual changes: %s", commitFiles)
	}
}

func TestPublishWorkspaceChangesBypassesCommitHooksByDefault(t *testing.T) {
	tmp := t.TempDir()
	alphaRoot := createGitSource(t, tmp, "repo-alpha")
	installFailingPreCommitHook(t, alphaRoot)
	request := testWorkspaceRequest("repo-alpha")
	request.PublishPolicy = &WorkspacePublishPolicy{
		Mode:          "commit_all_edit_target_changes_on_worker_success",
		CommitMessage: "A3 implementation update for Sample#42",
	}
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{"repo-alpha": alphaRoot},
	}
	prepared, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(prepared.Root, "repo_alpha", "change.txt"), []byte("change\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	err = PublishWorkspaceChanges(prepared, request, map[string]any{"success": true}, true)

	if err != nil {
		t.Fatalf("default publish hook bypass should commit despite failing pre-commit hook: %v", err)
	}
}

func TestPublishWorkspaceChangesRunsCommitHooksWhenRequested(t *testing.T) {
	tmp := t.TempDir()
	alphaRoot := createGitSource(t, tmp, "repo-alpha")
	installFailingPreCommitHook(t, alphaRoot)
	request := testWorkspaceRequest("repo-alpha")
	request.PublishPolicy = &WorkspacePublishPolicy{
		Mode:          "commit_all_edit_target_changes_on_worker_success",
		CommitMessage: "A3 implementation update for Sample#42",
		CommitPreflight: WorkspaceCommitPreflight{
			NativeGitHooks: "run",
		},
	}
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{"repo-alpha": alphaRoot},
	}
	prepared, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	beforeHead := trimTrailingNewline(git(t, alphaRoot, "rev-parse", "a3/work/Sample-42"))
	if err := os.WriteFile(filepath.Join(prepared.Root, "repo_alpha", "change.txt"), []byte("change\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	err = PublishWorkspaceChanges(prepared, request, map[string]any{"success": true}, true)

	if err == nil || !strings.Contains(err.Error(), "pre-commit blocked") {
		t.Fatalf("expected failing pre-commit hook to block publish, got %v", err)
	}
	if head := trimTrailingNewline(git(t, alphaRoot, "rev-parse", "a3/work/Sample-42")); head != beforeHead {
		t.Fatalf("branch advanced despite failing pre-commit hook: before=%s after=%s", beforeHead, head)
	}
}

func TestPublishWorkspaceChangesRunsCommitPreflightCommands(t *testing.T) {
	tmp := t.TempDir()
	alphaRoot := createGitSource(t, tmp, "repo-alpha")
	request := testWorkspaceRequest("repo-alpha")
	request.PublishPolicy = &WorkspacePublishPolicy{
		Mode:          "commit_all_edit_target_changes_on_worker_success",
		CommitMessage: "A3 implementation update for Sample#42",
		CommitPreflight: WorkspaceCommitPreflight{
			Commands: []string{"test -f change.txt"},
		},
	}
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{"repo-alpha": alphaRoot},
	}
	prepared, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(prepared.Root, "repo_alpha", "change.txt"), []byte("change\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	err = PublishWorkspaceChanges(prepared, request, map[string]any{"success": true}, true)

	if err != nil {
		t.Fatalf("commit preflight command should pass: %v", err)
	}
	descriptor := prepared.SlotDescriptors["repo_alpha"]
	if descriptor["commit_preflight_status"] != "succeeded" {
		t.Fatalf("expected preflight success evidence, got %#v", descriptor)
	}
}

func TestPublishWorkspaceChangesFailsWhenCommitPreflightCommandFails(t *testing.T) {
	tmp := t.TempDir()
	alphaRoot := createGitSource(t, tmp, "repo-alpha")
	request := testWorkspaceRequest("repo-alpha")
	request.PublishPolicy = &WorkspacePublishPolicy{
		Mode:          "commit_all_edit_target_changes_on_worker_success",
		CommitMessage: "A3 implementation update for Sample#42",
		CommitPreflight: WorkspaceCommitPreflight{
			Commands: []string{"printf preflight-blocked >&2; exit 7"},
		},
	}
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{"repo-alpha": alphaRoot},
	}
	prepared, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	beforeHead := trimTrailingNewline(git(t, alphaRoot, "rev-parse", "a3/work/Sample-42"))
	if err := os.WriteFile(filepath.Join(prepared.Root, "repo_alpha", "change.txt"), []byte("change\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	err = PublishWorkspaceChanges(prepared, request, map[string]any{"success": true}, true)

	if err == nil || !strings.Contains(err.Error(), "commit_preflight.commands[0]") || !strings.Contains(err.Error(), "preflight-blocked") {
		t.Fatalf("expected commit preflight command failure, got %v", err)
	}
	if head := trimTrailingNewline(git(t, alphaRoot, "rev-parse", "a3/work/Sample-42")); head != beforeHead {
		t.Fatalf("branch advanced despite failing preflight command: before=%s after=%s", beforeHead, head)
	}
}

func TestPublishWorkspaceChangesFailsWhenCommitPreflightCommandMutatesFiles(t *testing.T) {
	tmp := t.TempDir()
	alphaRoot := createGitSource(t, tmp, "repo-alpha")
	request := testWorkspaceRequest("repo-alpha")
	request.PublishPolicy = &WorkspacePublishPolicy{
		Mode:          "commit_all_edit_target_changes_on_worker_success",
		CommitMessage: "A3 implementation update for Sample#42",
		CommitPreflight: WorkspaceCommitPreflight{
			Commands: []string{"printf mutated >> change.txt && git add change.txt"},
		},
	}
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{"repo-alpha": alphaRoot},
	}
	prepared, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	beforeHead := trimTrailingNewline(git(t, alphaRoot, "rev-parse", "a3/work/Sample-42"))
	if err := os.WriteFile(filepath.Join(prepared.Root, "repo_alpha", "change.txt"), []byte("change\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	err = PublishWorkspaceChanges(prepared, request, map[string]any{"success": true}, true)

	if err == nil || !strings.Contains(err.Error(), "mutated slot repo_alpha") {
		t.Fatalf("expected commit preflight mutation failure, got %v", err)
	}
	if head := trimTrailingNewline(git(t, alphaRoot, "rev-parse", "a3/work/Sample-42")); head != beforeHead {
		t.Fatalf("branch advanced despite mutating preflight command: before=%s after=%s", beforeHead, head)
	}
}

func TestRunCompletionHooksAllowsMutatingHookOnEditSlot(t *testing.T) {
	tmp := t.TempDir()
	alphaRoot := createGitSource(t, tmp, "repo-alpha")
	request := testWorkspaceRequest("repo-alpha")
	request.CompletionHooks = []WorkspaceCompletionHook{
		{
			Name:      "fmt",
			Command:   "printf formatted > formatted.txt",
			Mode:      "mutating",
			OnFailure: "rework",
		},
	}
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{"repo-alpha": alphaRoot},
	}
	prepared, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(prepared.Root, "repo_alpha", "changed.txt"), []byte("changed\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	report, err := RunCompletionHooks(prepared, request)

	if err != nil {
		t.Fatalf("completion hook should pass: %v", err)
	}
	if report.Status != "succeeded" || len(report.Entries) != 1 {
		t.Fatalf("unexpected hook report: %#v", report)
	}
	changed, err := gitChangedPaths(filepath.Join(prepared.Root, "repo_alpha"))
	if err != nil {
		t.Fatal(err)
	}
	if join(changed) != "changed.txt,formatted.txt" {
		t.Fatalf("mutating hook output should remain dirty, got %v", changed)
	}
}

func TestRunCompletionHooksRejectsCheckModeMutationAndRestoresHookEffects(t *testing.T) {
	tmp := t.TempDir()
	alphaRoot := createGitSource(t, tmp, "repo-alpha")
	request := testWorkspaceRequest("repo-alpha")
	request.CompletionHooks = []WorkspaceCompletionHook{
		{
			Name:      "fmt",
			Command:   "printf formatted > formatted.txt",
			Mode:      "mutating",
			OnFailure: "rework",
		},
		{
			Name:      "verify",
			Command:   "printf illegal > illegal.txt",
			Mode:      "check",
			OnFailure: "rework",
		},
	}
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{"repo-alpha": alphaRoot},
	}
	prepared, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(prepared.Root, "repo_alpha", "changed.txt"), []byte("changed\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	report, err := RunCompletionHooks(prepared, request)

	if err == nil || !strings.Contains(err.Error(), "mutated slot repo_alpha in check mode") {
		t.Fatalf("expected check mutation failure, got report=%#v err=%v", report, err)
	}
	changed, err := gitChangedPaths(filepath.Join(prepared.Root, "repo_alpha"))
	if err != nil {
		t.Fatal(err)
	}
	if join(changed) != "changed.txt,formatted.txt" {
		t.Fatalf("failed hook side effects should be restored while prior successful hooks remain, got %v", changed)
	}
	if _, err := os.Stat(filepath.Join(prepared.Root, "repo_alpha", "illegal.txt")); !os.IsNotExist(err) {
		t.Fatalf("failed check hook file should be removed, err=%v", err)
	}
}

func TestRunCompletionHooksRejectsNonTargetSlotMutation(t *testing.T) {
	tmp := t.TempDir()
	alphaRoot := createGitSource(t, tmp, "repo-alpha")
	betaRoot := createGitSource(t, tmp, "repo-beta")
	request := testWorkspaceRequest("repo-alpha")
	request.Slots["repo_beta"] = WorkspaceSlotRequest{
		Source:    WorkspaceSourceRequest{Kind: "local_git", Alias: "repo-beta"},
		Ref:       "refs/heads/a3/work/Sample-42",
		Checkout:  "worktree_branch",
		Access:    "read_only",
		SyncClass: "lazy_but_guaranteed",
		Ownership: "support",
		Required:  true,
	}
	request.CompletionHooks = []WorkspaceCompletionHook{
		{
			Name:      "fmt",
			Command:   "printf leak > \"$A2O_WORKSPACE_ROOT/repo_beta/leak.txt\"",
			Mode:      "mutating",
			OnFailure: "rework",
		},
	}
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"repo-alpha": alphaRoot,
			"repo-beta":  betaRoot,
		},
	}
	prepared, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(prepared.Root, "repo_alpha", "changed.txt"), []byte("changed\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	report, err := RunCompletionHooks(prepared, request)

	if err == nil || !strings.Contains(err.Error(), "mutated non-target slot repo_beta") {
		t.Fatalf("expected non-target mutation failure, got report=%#v err=%v", report, err)
	}
	if _, err := os.Stat(filepath.Join(prepared.Root, "repo_beta", "leak.txt")); !os.IsNotExist(err) {
		t.Fatalf("non-target hook mutation should be restored, err=%v", err)
	}
	changed, err := gitChangedPaths(filepath.Join(prepared.Root, "repo_alpha"))
	if err != nil {
		t.Fatal(err)
	}
	if join(changed) != "changed.txt" {
		t.Fatalf("target slot should be restored to pre-hook state, got %v", changed)
	}
}

func TestPublishWorkspaceChangesRejectsSupportSlotChangesDuringCommandPublish(t *testing.T) {
	tmp := t.TempDir()
	alphaRoot := createGitSource(t, tmp, "repo-alpha")
	betaRoot := createGitSource(t, tmp, "repo-beta")
	request := testWorkspaceRequest("repo-alpha")
	request.PublishPolicy = &WorkspacePublishPolicy{Mode: "commit_all_edit_target_changes_on_success", CommitMessage: "remediate"}
	request.Slots["repo_beta"] = WorkspaceSlotRequest{
		Source:    WorkspaceSourceRequest{Kind: "local_git", Alias: "repo-beta"},
		Ref:       "refs/heads/a3/work/Sample-42",
		Checkout:  "worktree_branch",
		Access:    "read_only",
		SyncClass: "lazy_but_guaranteed",
		Ownership: "support",
		Required:  true,
	}
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{"repo-alpha": alphaRoot, "repo-beta": betaRoot},
	}
	prepared, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(prepared.Root, "repo_beta", "unexpected.txt"), []byte("unexpected\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	err = PublishWorkspaceChanges(prepared, request, nil, true)

	if err == nil || !strings.Contains(err.Error(), "repo_beta has changes but is not an edit target") {
		t.Fatalf("expected support slot mutation failure, got %v", err)
	}
}

func TestPublishWorkspaceChangesRollsBackAlreadyCommittedSlots(t *testing.T) {
	tmp := t.TempDir()
	alphaRoot := createGitSource(t, tmp, "repo-alpha")
	request := testWorkspaceRequest("repo-alpha")
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"repo-alpha": alphaRoot,
		},
	}
	prepared, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	alphaHead := git(t, alphaRoot, "rev-parse", "a3/work/Sample-42")
	if err := os.WriteFile(filepath.Join(prepared.Root, "repo_alpha", "alpha.txt"), []byte("alpha\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	prepared.SlotDescriptors["repo_beta"] = map[string]any{}

	err = executePublishPlans(prepared, []publishPlan{
		{slotName: "repo_alpha", runtimePath: filepath.Join(prepared.Root, "repo_alpha"), declared: []string{"alpha.txt"}},
		{slotName: "repo_beta", runtimePath: filepath.Join(prepared.Root, "missing-repo"), declared: []string{"beta.txt"}},
	}, "test rollback", "bypass", nil)

	if err == nil || !strings.Contains(err.Error(), "rev-parse") {
		t.Fatalf("expected publish failure after first commit, got %v", err)
	}
	if head := git(t, alphaRoot, "rev-parse", "a3/work/Sample-42"); head != alphaHead {
		t.Fatalf("repo_alpha branch was not rolled back: before=%s after=%s", alphaHead, head)
	}
	if resolved := prepared.SlotDescriptors["repo_alpha"]["resolved_head"]; resolved != trimTrailingNewline(alphaHead) {
		t.Fatalf("repo_alpha descriptor resolved_head was not restored: %#v", prepared.SlotDescriptors["repo_alpha"])
	}
	if _, ok := prepared.SlotDescriptors["repo_beta"]["published_changed_files"]; ok {
		t.Fatalf("rollback did not clear current failed slot evidence: %#v", prepared.SlotDescriptors["repo_beta"])
	}
}

func TestPublishWorkspaceChangesRollsBackCurrentSlotOnStageFailure(t *testing.T) {
	tmp := t.TempDir()
	alphaRoot := createGitSource(t, tmp, "repo-alpha")
	request := testWorkspaceRequest("repo-alpha")
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"repo-alpha": alphaRoot,
		},
	}
	prepared, err := materializer.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	alphaPath := filepath.Join(prepared.Root, "repo_alpha")
	if err := os.WriteFile(filepath.Join(alphaPath, "alpha.txt"), []byte("alpha\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	err = executePublishPlans(prepared, []publishPlan{
		{slotName: "repo_alpha", runtimePath: alphaPath, declared: []string{"missing.txt"}},
	}, "test rollback current", "bypass", nil)

	if err == nil || !strings.Contains(err.Error(), "add") {
		t.Fatalf("expected stage failure, got %v", err)
	}
	if _, err := os.Stat(filepath.Join(alphaPath, "alpha.txt")); !os.IsNotExist(err) {
		t.Fatalf("rollback did not clean current slot untracked file: %v", err)
	}
	descriptor := prepared.SlotDescriptors["repo_alpha"]
	if _, ok := descriptor["publish_status"]; ok {
		t.Fatalf("rollback did not clear publish evidence: %#v", descriptor)
	}
}

func TestWorkspaceMaterializerMergesBranchRefs(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "repo-alpha")
	if err := os.WriteFile(filepath.Join(sourceRoot, "feature.txt"), []byte("feature\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, sourceRoot, "add", "feature.txt")
	git(t, sourceRoot, "commit", "-q", "-m", "feature")
	git(t, sourceRoot, "branch", "-f", "a3/work/Sample-42", "HEAD")
	git(t, sourceRoot, "branch", "a3/live", "HEAD~1")
	before := git(t, sourceRoot, "rev-parse", "refs/heads/a3/live")
	source := git(t, sourceRoot, "rev-parse", "refs/heads/a3/work/Sample-42")

	descriptor, execution := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"repo-alpha": sourceRoot,
		},
	}.Merge(MergeRequest{
		WorkspaceID: "merge-Sample-42",
		Policy:      "ff_only",
		Slots: map[string]MergeSlotRequest{
			"repo_alpha": {
				Source: WorkspaceSourceRequest{
					Kind:  "local_git",
					Alias: "repo-alpha",
				},
				SourceRef: "refs/heads/a3/work/Sample-42",
				TargetRef: "refs/heads/a3/live",
			},
		},
	})

	if execution.Status != "succeeded" {
		t.Fatalf("merge failed: %#v", execution)
	}
	if head := git(t, sourceRoot, "rev-parse", "refs/heads/a3/live"); head != source {
		t.Fatalf("target branch was not advanced: got=%s want=%s", head, source)
	}
	slot := descriptor.SlotDescriptors["repo_alpha"]
	if slot["merge_before_head"] != trimTrailingNewline(before) || slot["merge_after_head"] != trimTrailingNewline(source) {
		t.Fatalf("unexpected merge descriptor: %#v", slot)
	}
	if slot["merge_status"] != "merged" || slot["project_repo_mutator"] != "a2o-agent" {
		t.Fatalf("missing agent merge evidence: %#v", slot)
	}
	mergeLog := string(execution.CombinedLog)
	for _, want := range []string{
		"A2O agent merge completed",
		"workspace_id=merge-Sample-42 policy=ff_only slots=1",
		"slot=repo_alpha status=merged source=refs/heads/a3/work/Sample-42 target=refs/heads/a3/live",
	} {
		if !strings.Contains(mergeLog, want) {
			t.Fatalf("merge log missing %q in:\n%s", want, mergeLog)
		}
	}
	if out := git(t, sourceRoot, "worktree", "list", "--porcelain"); strings.Contains(out, "merge-Sample-42") {
		t.Fatalf("merge worktree leaked: %s", out)
	}
}

func TestWorkspaceMaterializerPushesRemoteBranchDelivery(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "repo-alpha")
	remoteRoot := filepath.Join(tmp, "origin.git")
	hookPath := filepath.Join(tmp, "after-push.sh")
	eventPath := filepath.Join(tmp, "after-push-event.json")
	if err := os.WriteFile(hookPath, []byte("#!/bin/sh\ncat > \"$1\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	git(t, tmp, "init", "--bare", "-q", remoteRoot)
	git(t, sourceRoot, "remote", "add", "origin", remoteRoot)
	git(t, sourceRoot, "push", "-q", "origin", "HEAD:refs/heads/main")
	if err := os.WriteFile(filepath.Join(sourceRoot, "feature.txt"), []byte("feature\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, sourceRoot, "add", "feature.txt")
	git(t, sourceRoot, "commit", "-q", "-m", "feature")
	git(t, sourceRoot, "branch", "-f", "a2o/work/Sample-42", "HEAD")
	source := trimTrailingNewline(git(t, sourceRoot, "rev-parse", "refs/heads/a2o/work/Sample-42"))

	descriptor, execution := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"repo-alpha": sourceRoot,
		},
	}.Merge(MergeRequest{
		WorkspaceID:    "merge-Sample-42",
		Policy:         "ff_only",
		TaskRef:        "Sample#42",
		ExternalTaskID: intPtr(42),
		Delivery: &MergeDeliveryRequest{
			Mode:             "remote_branch",
			Remote:           "origin",
			BaseBranch:       "main",
			Push:             true,
			Sync:             map[string]string{"before_push": "fetch"},
			AfterPushCommand: []string{hookPath, eventPath},
		},
		Slots: map[string]MergeSlotRequest{
			"repo_alpha": {
				Source: WorkspaceSourceRequest{
					Kind:  "local_git",
					Alias: "repo-alpha",
				},
				SourceRef:    "refs/heads/a2o/work/Sample-42",
				TargetRef:    "refs/heads/a2o/tasks/Sample-42",
				BootstrapRef: "refs/remotes/origin/main",
			},
		},
	})

	if execution.Status != "succeeded" {
		t.Fatalf("merge failed: %#v", execution)
	}
	if head := trimTrailingNewline(git(t, remoteRoot, "rev-parse", "refs/heads/a2o/tasks/Sample-42")); head != source {
		t.Fatalf("remote branch was not pushed: got=%s want=%s", head, source)
	}
	slot := descriptor.SlotDescriptors["repo_alpha"]
	if slot["delivery_mode"] != "remote_branch" || slot["remote"] != "origin" || slot["push_status"] != "pushed" {
		t.Fatalf("missing remote branch delivery evidence: %#v", slot)
	}
	if slot["after_push_status"] != "succeeded" {
		t.Fatalf("missing after_push evidence: %#v", slot)
	}
	eventBytes, err := os.ReadFile(eventPath)
	if err != nil {
		t.Fatal(err)
	}
	var event map[string]any
	if err := json.Unmarshal(eventBytes, &event); err != nil {
		t.Fatal(err)
	}
	if event["task_ref"] != "Sample#42" || event["remote"] != "origin" || event["base_branch"] != "main" ||
		event["branch"] != "a2o/tasks/Sample-42" || event["pushed_ref"] != "refs/heads/a2o/tasks/Sample-42" ||
		event["commit"] != source || event["slot"] != "repo_alpha" {
		t.Fatalf("unexpected after_push event: %#v", event)
	}
	remoteIssue, ok := event["remote_issue"].(map[string]any)
	if !ok || remoteIssue["id"] != float64(42) {
		t.Fatalf("unexpected remote issue event: %#v", event["remote_issue"])
	}
	mergeLog := string(execution.CombinedLog)
	if !strings.Contains(mergeLog, "push=pushed remote=origin branch=a2o/tasks/Sample-42") {
		t.Fatalf("merge log missing push evidence:\n%s", mergeLog)
	}
}

func TestWorkspaceMaterializerFailsWhenRemoteBranchAfterPushHookFails(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "repo-alpha")
	remoteRoot := filepath.Join(tmp, "origin.git")
	hookPath := filepath.Join(tmp, "after-push-fail.sh")
	if err := os.WriteFile(hookPath, []byte("#!/bin/sh\ncat >/dev/null\necho hook failed >&2\nexit 23\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	git(t, tmp, "init", "--bare", "-q", remoteRoot)
	git(t, sourceRoot, "remote", "add", "origin", remoteRoot)
	git(t, sourceRoot, "push", "-q", "origin", "HEAD:refs/heads/main")
	if err := os.WriteFile(filepath.Join(sourceRoot, "feature.txt"), []byte("feature\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, sourceRoot, "add", "feature.txt")
	git(t, sourceRoot, "commit", "-q", "-m", "feature")
	git(t, sourceRoot, "branch", "-f", "a2o/work/Sample-42", "HEAD")

	descriptor, execution := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"repo-alpha": sourceRoot,
		},
	}.Merge(MergeRequest{
		WorkspaceID: "merge-Sample-42",
		Policy:      "ff_only",
		TaskRef:     "Sample#42",
		Delivery: &MergeDeliveryRequest{
			Mode:             "remote_branch",
			Remote:           "origin",
			BaseBranch:       "main",
			Push:             true,
			Sync:             map[string]string{"before_push": "fetch"},
			AfterPushCommand: []string{hookPath},
		},
		Slots: map[string]MergeSlotRequest{
			"repo_alpha": {
				Source: WorkspaceSourceRequest{
					Kind:  "local_git",
					Alias: "repo-alpha",
				},
				SourceRef:    "refs/heads/a2o/work/Sample-42",
				TargetRef:    "refs/heads/a2o/tasks/Sample-42",
				BootstrapRef: "refs/remotes/origin/main",
			},
		},
	})

	if execution.Status != "failed" || !strings.Contains(string(execution.CombinedLog), "after_push command failed") {
		t.Fatalf("expected after_push failure, got %#v", execution)
	}
	slot := descriptor.SlotDescriptors["repo_alpha"]
	if slot["after_push_status"] != "failed" || !strings.Contains(fmt.Sprint(slot["after_push_log"]), "hook failed") {
		t.Fatalf("missing after_push failure evidence: %#v", slot)
	}
}

func TestWorkspaceMaterializerBootstrapsRemoteBranchDeliveryFromExistingRemoteTaskBranch(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "repo-alpha")
	remoteRoot := filepath.Join(tmp, "origin.git")
	git(t, tmp, "init", "--bare", "-q", remoteRoot)
	git(t, sourceRoot, "remote", "add", "origin", remoteRoot)
	git(t, sourceRoot, "push", "-q", "origin", "HEAD:refs/heads/main")
	if err := os.WriteFile(filepath.Join(sourceRoot, "remote-task.txt"), []byte("remote task\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, sourceRoot, "add", "remote-task.txt")
	git(t, sourceRoot, "commit", "-q", "-m", "remote task seed")
	remoteTaskHead := trimTrailingNewline(git(t, sourceRoot, "rev-parse", "HEAD"))
	git(t, sourceRoot, "push", "-q", "origin", "HEAD:refs/heads/a2o/tasks/Sample-42")
	if err := os.WriteFile(filepath.Join(sourceRoot, "feature.txt"), []byte("feature\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, sourceRoot, "add", "feature.txt")
	git(t, sourceRoot, "commit", "-q", "-m", "feature")
	git(t, sourceRoot, "branch", "-f", "a2o/work/Sample-42", "HEAD")
	source := trimTrailingNewline(git(t, sourceRoot, "rev-parse", "refs/heads/a2o/work/Sample-42"))

	descriptor, execution := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"repo-alpha": sourceRoot,
		},
	}.Merge(MergeRequest{
		WorkspaceID: "merge-Sample-42",
		Policy:      "ff_only",
		Delivery: &MergeDeliveryRequest{
			Mode:       "remote_branch",
			Remote:     "origin",
			BaseBranch: "main",
			Push:       true,
			Sync:       map[string]string{"before_push": "fetch"},
		},
		Slots: map[string]MergeSlotRequest{
			"repo_alpha": {
				Source: WorkspaceSourceRequest{
					Kind:  "local_git",
					Alias: "repo-alpha",
				},
				SourceRef:    "refs/heads/a2o/work/Sample-42",
				TargetRef:    "refs/heads/a2o/tasks/Sample-42",
				BootstrapRef: "refs/remotes/origin/main",
			},
		},
	})

	if execution.Status != "succeeded" {
		t.Fatalf("merge failed: %#v", execution)
	}
	if head := trimTrailingNewline(git(t, remoteRoot, "rev-parse", "refs/heads/a2o/tasks/Sample-42")); head != source {
		t.Fatalf("remote branch was not advanced: got=%s want=%s", head, source)
	}
	slot := descriptor.SlotDescriptors["repo_alpha"]
	if slot["merge_before_head"] != remoteTaskHead {
		t.Fatalf("merge did not bootstrap from existing remote task branch: got=%v want=%s slot=%#v", slot["merge_before_head"], remoteTaskHead, slot)
	}
	if slot["merge_bootstrap_ref"] != "refs/remotes/origin/a2o/tasks/Sample-42" {
		t.Fatalf("unexpected bootstrap ref: %#v", slot)
	}
}

func TestWorkspaceMaterializerRejectsUnknownMergePolicy(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "repo-alpha")

	_, execution := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"repo-alpha": sourceRoot,
		},
	}.Merge(MergeRequest{
		WorkspaceID: "merge-Sample-42",
		Policy:      "surprising_policy",
		Slots: map[string]MergeSlotRequest{
			"repo_alpha": {
				Source: WorkspaceSourceRequest{
					Kind:  "local_git",
					Alias: "repo-alpha",
				},
				SourceRef: "refs/heads/a3/work/Sample-42",
				TargetRef: "refs/heads/a3/live",
			},
		},
	})

	if execution.Status != "failed" || !strings.Contains(string(execution.CombinedLog), "unsupported merge policy") {
		t.Fatalf("expected unsupported policy failure, got %#v", execution)
	}
}

func TestWorkspaceMaterializerRetainsMergeWorkspaceOnContentConflict(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "repo-alpha")
	if err := os.WriteFile(filepath.Join(sourceRoot, "conflict.txt"), []byte("base\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, sourceRoot, "add", "conflict.txt")
	gitTestCommit(t, sourceRoot, "base conflict file")
	base := trimTrailingNewline(git(t, sourceRoot, "rev-parse", "HEAD"))
	git(t, sourceRoot, "branch", "-f", "a3/live", base)
	git(t, sourceRoot, "branch", "-f", "a3/work/Sample-42", base)

	git(t, sourceRoot, "checkout", "-q", "-B", "target-edit", "a3/live")
	if err := os.WriteFile(filepath.Join(sourceRoot, "conflict.txt"), []byte("target\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, sourceRoot, "add", "conflict.txt")
	gitTestCommit(t, sourceRoot, "target edit")
	targetHead := trimTrailingNewline(git(t, sourceRoot, "rev-parse", "HEAD"))
	git(t, sourceRoot, "branch", "-f", "a3/live", targetHead)

	git(t, sourceRoot, "checkout", "-q", "-B", "source-edit", base)
	if err := os.WriteFile(filepath.Join(sourceRoot, "conflict.txt"), []byte("source\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, sourceRoot, "add", "conflict.txt")
	gitTestCommit(t, sourceRoot, "source edit")
	sourceHead := trimTrailingNewline(git(t, sourceRoot, "rev-parse", "HEAD"))
	git(t, sourceRoot, "branch", "-f", "a3/work/Sample-42", sourceHead)

	descriptor, execution := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"repo-alpha": sourceRoot,
		},
	}.Merge(MergeRequest{
		WorkspaceID: "merge-Sample-42",
		Policy:      "ff_or_merge",
		Slots: map[string]MergeSlotRequest{
			"repo_alpha": {
				Source: WorkspaceSourceRequest{
					Kind:  "local_git",
					Alias: "repo-alpha",
				},
				SourceRef: "refs/heads/a3/work/Sample-42",
				TargetRef: "refs/heads/a3/live",
			},
		},
	})

	if execution.Status != "failed" {
		t.Fatalf("expected merge conflict failure, got %#v", execution)
	}
	slot := descriptor.SlotDescriptors["repo_alpha"]
	if slot["merge_status"] != "conflicted" || slot["merge_recovery_candidate"] != true {
		t.Fatalf("missing recovery candidate evidence: %#v", slot)
	}
	conflictFiles, ok := slot["conflict_files"].([]string)
	if !ok || len(conflictFiles) != 1 || conflictFiles[0] != "conflict.txt" {
		t.Fatalf("unexpected conflict files: %#v", slot["conflict_files"])
	}
	runtimePath, ok := slot["runtime_path"].(string)
	if !ok || runtimePath == "" {
		t.Fatalf("missing runtime path: %#v", slot)
	}
	if _, err := os.Stat(runtimePath); err != nil {
		t.Fatalf("merge workspace was not retained: %v", err)
	}
	if head := trimTrailingNewline(git(t, sourceRoot, "rev-parse", "refs/heads/a3/live")); head != targetHead {
		t.Fatalf("target branch advanced during conflicted merge: got=%s want=%s", head, targetHead)
	}
	if status := git(t, runtimePath, "status", "--porcelain"); !strings.Contains(status, "UU conflict.txt") {
		t.Fatalf("retained workspace does not contain unresolved conflict: %s", status)
	}
	if !strings.Contains(string(execution.CombinedLog), "CONFLICT") {
		t.Fatalf("merge conflict log was not preserved: %s", execution.CombinedLog)
	}
}

func TestWorkspaceMaterializerRollsBackNonRecoverableMergeConflict(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "repo-alpha")
	base := trimTrailingNewline(git(t, sourceRoot, "rev-parse", "HEAD"))
	git(t, sourceRoot, "branch", "-f", "a3/live", base)
	git(t, sourceRoot, "branch", "-f", "a3/work/Sample-42", base)

	git(t, sourceRoot, "checkout", "-q", "-B", "target-edit", "a3/live")
	if err := os.WriteFile(filepath.Join(sourceRoot, "duplicate.txt"), []byte("target\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, sourceRoot, "add", "duplicate.txt")
	gitTestCommit(t, sourceRoot, "target adds duplicate file")
	targetHead := trimTrailingNewline(git(t, sourceRoot, "rev-parse", "HEAD"))
	git(t, sourceRoot, "branch", "-f", "a3/live", targetHead)

	git(t, sourceRoot, "checkout", "-q", "-B", "source-edit", base)
	if err := os.WriteFile(filepath.Join(sourceRoot, "duplicate.txt"), []byte("source\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, sourceRoot, "add", "duplicate.txt")
	gitTestCommit(t, sourceRoot, "source adds duplicate file")
	sourceHead := trimTrailingNewline(git(t, sourceRoot, "rev-parse", "HEAD"))
	git(t, sourceRoot, "branch", "-f", "a3/work/Sample-42", sourceHead)

	descriptor, execution := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"repo-alpha": sourceRoot,
		},
	}.Merge(MergeRequest{
		WorkspaceID: "merge-Sample-42",
		Policy:      "ff_or_merge",
		Slots: map[string]MergeSlotRequest{
			"repo_alpha": {
				Source: WorkspaceSourceRequest{
					Kind:  "local_git",
					Alias: "repo-alpha",
				},
				SourceRef: "refs/heads/a3/work/Sample-42",
				TargetRef: "refs/heads/a3/live",
			},
		},
	})

	if execution.Status != "failed" {
		t.Fatalf("expected non-recoverable merge conflict failure, got %#v", execution)
	}
	slot := descriptor.SlotDescriptors["repo_alpha"]
	if slot["merge_recovery_candidate"] != false || slot["merge_recovery_workspace_retained"] != false {
		t.Fatalf("non-recoverable conflict must not be a recovery candidate: %#v", slot)
	}
	if slot["merge_status"] != "failed" {
		t.Fatalf("expected failed merge status after rollback: %#v", slot)
	}
	statuses, ok := slot["conflict_statuses"].(map[string]string)
	if !ok || statuses["duplicate.txt"] != "AA" {
		t.Fatalf("unexpected conflict statuses: %#v", slot["conflict_statuses"])
	}
	runtimePath, ok := slot["runtime_path"].(string)
	if !ok || runtimePath == "" {
		t.Fatalf("missing runtime path: %#v", slot)
	}
	if _, err := os.Stat(runtimePath); !os.IsNotExist(err) {
		t.Fatalf("non-recoverable merge workspace should be removed, stat err=%v", err)
	}
	if head := trimTrailingNewline(git(t, sourceRoot, "rev-parse", "refs/heads/a3/live")); head != targetHead {
		t.Fatalf("target branch advanced during failed merge: got=%s want=%s", head, targetHead)
	}
}

func TestWorkspaceMaterializerFinalizesRecoveredMergeWorkspace(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "repo-alpha")
	targetHead, sourceHead, runtimePath := createRetainedContentConflict(t, tmp, sourceRoot)
	if err := os.WriteFile(filepath.Join(runtimePath, "conflict.txt"), []byte("target\nsource\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	descriptor, execution := WorkspaceMaterializer{}.RecoverMerge(MergeRecoveryRequest{
		WorkspaceID: "merge-Sample-42",
		Slots: map[string]MergeRecoverySlotRequest{
			"repo_alpha": {
				RuntimePath:      runtimePath,
				TargetRef:        "refs/heads/a3/live",
				SourceRef:        "refs/heads/a3/work/Sample-42",
				MergeBeforeHead:  targetHead,
				SourceHeadCommit: sourceHead,
				ConflictFiles:    []string{"conflict.txt"},
				CommitMessage:    "Recover Sample#42 merge",
			},
		},
	})

	if execution.Status != "succeeded" {
		t.Fatalf("expected recovered merge success, got %#v", execution)
	}
	slot := descriptor.SlotDescriptors["repo_alpha"]
	if slot["merge_status"] != "recovered" {
		t.Fatalf("expected recovered merge evidence: %#v", slot)
	}
	if slot["publish_before_head"] != targetHead {
		t.Fatalf("unexpected publish_before_head: %#v", slot)
	}
	afterHead, ok := slot["publish_after_head"].(string)
	if !ok || afterHead == "" || afterHead == targetHead {
		t.Fatalf("unexpected publish_after_head: %#v", slot)
	}
	if head := trimTrailingNewline(git(t, sourceRoot, "rev-parse", "refs/heads/a3/live")); head != afterHead {
		t.Fatalf("target branch did not advance to recovered merge commit: got=%s want=%s", head, afterHead)
	}
	parents := strings.Fields(git(t, runtimePath, "rev-list", "--parents", "-n", "1", "HEAD"))
	if len(parents) != 3 || parents[1] != targetHead || parents[2] != sourceHead {
		t.Fatalf("expected recovered merge commit with target/source parents, got %v", parents)
	}
	if status := git(t, runtimePath, "status", "--porcelain"); status != "" {
		t.Fatalf("recovered workspace should be clean: %s", status)
	}
}

func TestWorkspaceMaterializerRejectsRecoveredMergeWithConflictMarkers(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "repo-alpha")
	targetHead, sourceHead, runtimePath := createRetainedContentConflict(t, tmp, sourceRoot)

	descriptor, execution := WorkspaceMaterializer{}.RecoverMerge(MergeRecoveryRequest{
		WorkspaceID: "merge-Sample-42",
		Slots: map[string]MergeRecoverySlotRequest{
			"repo_alpha": {
				RuntimePath:      runtimePath,
				TargetRef:        "refs/heads/a3/live",
				SourceRef:        "refs/heads/a3/work/Sample-42",
				MergeBeforeHead:  targetHead,
				SourceHeadCommit: sourceHead,
				ConflictFiles:    []string{"conflict.txt"},
			},
		},
	})

	if execution.Status != "failed" {
		t.Fatalf("expected marker scan failure, got %#v", execution)
	}
	slot := descriptor.SlotDescriptors["repo_alpha"]
	if slot["merge_status"] != "recovery_failed" {
		t.Fatalf("expected recovery_failed evidence: %#v", slot)
	}
	markerResult, ok := slot["marker_scan_result"].(map[string]any)
	if !ok {
		t.Fatalf("missing marker scan result: %#v", slot)
	}
	unresolved, ok := markerResult["unresolved_files"].([]string)
	if !ok || len(unresolved) != 1 || unresolved[0] != "conflict.txt" {
		t.Fatalf("unexpected marker scan result: %#v", markerResult)
	}
	if head := trimTrailingNewline(git(t, sourceRoot, "rev-parse", "refs/heads/a3/live")); head != targetHead {
		t.Fatalf("target branch advanced after rejected recovery: got=%s want=%s", head, targetHead)
	}
}

func TestWorkspaceMaterializerDoesNotPartiallyPublishRecoveredMergeSlots(t *testing.T) {
	tmp := t.TempDir()
	firstRoot := createGitSource(t, tmp, "repo-alpha")
	firstTarget, firstSource, firstRuntime := createRetainedContentConflict(t, tmp, firstRoot)
	if err := os.WriteFile(filepath.Join(firstRuntime, "conflict.txt"), []byte("target\nsource\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	secondRoot := createGitSource(t, tmp, "repo-beta")
	secondTarget, secondSource, secondRuntime := createRetainedContentConflict(t, filepath.Join(tmp, "second"), secondRoot)

	descriptor, execution := WorkspaceMaterializer{}.RecoverMerge(MergeRecoveryRequest{
		WorkspaceID: "merge-Sample-42",
		Slots: map[string]MergeRecoverySlotRequest{
			"repo_alpha": {
				RuntimePath:      firstRuntime,
				TargetRef:        "refs/heads/a3/live",
				SourceRef:        "refs/heads/a3/work/Sample-42",
				MergeBeforeHead:  firstTarget,
				SourceHeadCommit: firstSource,
				ConflictFiles:    []string{"conflict.txt"},
			},
			"repo_beta": {
				RuntimePath:      secondRuntime,
				TargetRef:        "refs/heads/a3/live",
				SourceRef:        "refs/heads/a3/work/Sample-42",
				MergeBeforeHead:  secondTarget,
				SourceHeadCommit: secondSource,
				ConflictFiles:    []string{"conflict.txt"},
			},
		},
	})

	if execution.Status != "failed" {
		t.Fatalf("expected second slot marker failure, got %#v", execution)
	}
	if descriptor.SlotDescriptors["repo_alpha"]["merge_status"] != "recovery_prepared" {
		t.Fatalf("first slot should not be committed before all preflight passes: %#v", descriptor.SlotDescriptors["repo_alpha"])
	}
	if head := trimTrailingNewline(git(t, firstRoot, "rev-parse", "refs/heads/a3/live")); head != firstTarget {
		t.Fatalf("first target branch was partially published: got=%s want=%s", head, firstTarget)
	}
	if head := trimTrailingNewline(git(t, secondRoot, "rev-parse", "refs/heads/a3/live")); head != secondTarget {
		t.Fatalf("second target branch advanced after failed recovery: got=%s want=%s", head, secondTarget)
	}
}

func TestWorkspaceMaterializerRemovesBootstrappedTargetRefOnMergeFailure(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "repo-alpha")
	if err := os.WriteFile(filepath.Join(sourceRoot, "feature.txt"), []byte("feature\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, sourceRoot, "add", "feature.txt")
	git(t, sourceRoot, "commit", "-q", "-m", "feature")
	git(t, sourceRoot, "branch", "-f", "a3/work/Sample-42", "HEAD")

	_, execution := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"repo-alpha": sourceRoot,
		},
	}.Merge(MergeRequest{
		WorkspaceID: "merge-Sample-42",
		Policy:      "ff_only",
		Slots: map[string]MergeSlotRequest{
			"repo_alpha": {
				Source: WorkspaceSourceRequest{
					Kind:  "local_git",
					Alias: "repo-alpha",
				},
				SourceRef:    "refs/heads/missing-source",
				TargetRef:    "refs/heads/a3/live",
				BootstrapRef: "HEAD~1",
			},
		},
	})

	if execution.Status != "failed" {
		t.Fatalf("expected merge failure, got %#v", execution)
	}
	if out, err := gitMaybe(sourceRoot, "rev-parse", "--verify", "refs/heads/a3/live"); err == nil {
		t.Fatalf("bootstrapped target ref was not removed: %s", out)
	}
}

func TestWorkspaceMaterializerRollsBackBootstrappedTargetRefWhenLaterSlotIsInvalid(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "repo-alpha")

	_, execution := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"repo-alpha": sourceRoot,
		},
	}.Merge(MergeRequest{
		WorkspaceID: "merge-Sample-42",
		Policy:      "ff_only",
		Slots: map[string]MergeSlotRequest{
			"repo_alpha": {
				Source: WorkspaceSourceRequest{
					Kind:  "local_git",
					Alias: "repo-alpha",
				},
				SourceRef:    "refs/heads/a3/work/Sample-42",
				TargetRef:    "refs/heads/a3/live",
				BootstrapRef: "HEAD",
			},
			"repo_beta": {
				Source: WorkspaceSourceRequest{
					Kind:  "unsupported",
					Alias: "repo-alpha",
				},
				SourceRef: "refs/heads/a3/work/Sample-42",
				TargetRef: "refs/heads/a3/live-beta",
			},
		},
	})

	if execution.Status != "failed" {
		t.Fatalf("expected merge failure, got %#v", execution)
	}
	if out, err := gitMaybe(sourceRoot, "rev-parse", "--verify", "refs/heads/a3/live"); err == nil {
		t.Fatalf("bootstrapped target ref was not removed after plan validation failure: %s", out)
	}
}

func testWorkspaceRequest(sourceAlias string) WorkspaceRequest {
	return WorkspaceRequest{
		Mode:            "agent_materialized",
		WorkspaceKind:   "ticket_workspace",
		WorkspaceID:     "Sample-42-ticket",
		FreshnessPolicy: "reuse_if_clean_and_ref_matches",
		CleanupPolicy:   "retain_until_a3_cleanup",
		PublishPolicy: &WorkspacePublishPolicy{
			Mode:          "commit_declared_changes_on_success",
			CommitMessage: "A3 implementation update for Sample#42",
		},
		Slots: map[string]WorkspaceSlotRequest{
			"repo_alpha": {
				Source: WorkspaceSourceRequest{
					Kind:  "local_git",
					Alias: sourceAlias,
				},
				Ref:       "refs/heads/a3/work/Sample-42",
				Checkout:  "worktree_branch",
				Access:    "read_write",
				SyncClass: "eager",
				Ownership: "edit_target",
				Required:  true,
			},
		},
	}
}

func createGitSource(t *testing.T, root string, name string) string {
	t.Helper()
	sourceRoot := filepath.Join(root, name)
	if err := os.MkdirAll(sourceRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	git(t, sourceRoot, "init", "-q")
	git(t, sourceRoot, "config", "user.name", "A3 Test")
	git(t, sourceRoot, "config", "user.email", "a3-test@example.com")
	if err := os.WriteFile(filepath.Join(sourceRoot, "README.md"), []byte("source\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, sourceRoot, "add", "README.md")
	git(t, sourceRoot, "commit", "-q", "-m", "initial commit")
	git(t, sourceRoot, "branch", "a3/work/Sample-42", "HEAD")
	return sourceRoot
}

func installFailingPreCommitHook(t *testing.T, sourceRoot string) {
	t.Helper()
	hookDir := filepath.Join(sourceRoot, ".githooks")
	if err := os.MkdirAll(hookDir, 0o755); err != nil {
		t.Fatal(err)
	}
	hookPath := filepath.Join(hookDir, "pre-commit")
	if err := os.WriteFile(hookPath, []byte("#!/bin/sh\necho pre-commit blocked >&2\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	git(t, sourceRoot, "config", "core.hooksPath", ".githooks")
	git(t, sourceRoot, "add", ".githooks/pre-commit")
	git(t, sourceRoot, "commit", "-q", "-m", "add failing pre-commit hook")
	git(t, sourceRoot, "branch", "-f", "a3/work/Sample-42", "HEAD")
}

func createRetainedContentConflict(t *testing.T, tmp string, sourceRoot string) (string, string, string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(sourceRoot, "conflict.txt"), []byte("base\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, sourceRoot, "add", "conflict.txt")
	gitTestCommit(t, sourceRoot, "base conflict file")
	base := trimTrailingNewline(git(t, sourceRoot, "rev-parse", "HEAD"))
	git(t, sourceRoot, "branch", "-f", "a3/live", base)
	git(t, sourceRoot, "branch", "-f", "a3/work/Sample-42", base)

	git(t, sourceRoot, "checkout", "-q", "-B", "target-edit", "a3/live")
	if err := os.WriteFile(filepath.Join(sourceRoot, "conflict.txt"), []byte("target\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, sourceRoot, "add", "conflict.txt")
	gitTestCommit(t, sourceRoot, "target edit")
	targetHead := trimTrailingNewline(git(t, sourceRoot, "rev-parse", "HEAD"))
	git(t, sourceRoot, "branch", "-f", "a3/live", targetHead)

	git(t, sourceRoot, "checkout", "-q", "-B", "source-edit", base)
	if err := os.WriteFile(filepath.Join(sourceRoot, "conflict.txt"), []byte("source\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, sourceRoot, "add", "conflict.txt")
	gitTestCommit(t, sourceRoot, "source edit")
	sourceHead := trimTrailingNewline(git(t, sourceRoot, "rev-parse", "HEAD"))
	git(t, sourceRoot, "branch", "-f", "a3/work/Sample-42", sourceHead)

	descriptor, execution := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"repo-alpha": sourceRoot,
		},
	}.Merge(MergeRequest{
		WorkspaceID: "merge-Sample-42",
		Policy:      "ff_or_merge",
		Slots: map[string]MergeSlotRequest{
			"repo_alpha": {
				Source: WorkspaceSourceRequest{
					Kind:  "local_git",
					Alias: "repo-alpha",
				},
				SourceRef: "refs/heads/a3/work/Sample-42",
				TargetRef: "refs/heads/a3/live",
			},
		},
	})
	if execution.Status != "failed" {
		t.Fatalf("expected retained merge conflict, got %#v", execution)
	}
	runtimePath, ok := descriptor.SlotDescriptors["repo_alpha"]["runtime_path"].(string)
	if !ok || runtimePath == "" {
		t.Fatalf("missing retained runtime path: %#v", descriptor.SlotDescriptors["repo_alpha"])
	}
	return targetHead, sourceHead, runtimePath
}

func git(t *testing.T, root string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	cmd.Env = append(os.Environ(),
		"GIT_CONFIG_COUNT=2",
		"GIT_CONFIG_KEY_0=commit.gpgsign",
		"GIT_CONFIG_VALUE_0=false",
		"GIT_CONFIG_KEY_1=core.hooksPath",
		"GIT_CONFIG_VALUE_1=/dev/null",
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v failed: %v: %s", args, err, out)
	}
	return string(out)
}

func gitTestCommit(t *testing.T, root string, message string) string {
	t.Helper()
	return git(t, root, "-c", "commit.gpgsign=false", "commit", "--no-gpg-sign", "--no-verify", "-q", "-m", message)
}

func gitMaybe(root string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	cmd.Env = append(os.Environ(),
		"GIT_CONFIG_COUNT=2",
		"GIT_CONFIG_KEY_0=commit.gpgsign",
		"GIT_CONFIG_VALUE_0=false",
		"GIT_CONFIG_KEY_1=core.hooksPath",
		"GIT_CONFIG_VALUE_1=/dev/null",
	)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func contains(value, needle string) bool {
	return strings.Contains(value, needle)
}
