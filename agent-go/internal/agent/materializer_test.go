package agent

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestWorkspaceMaterializerPreparesAndCleansWorktreeSlots(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "member-portal-starters")
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"member-portal-starters": sourceRoot,
		},
	}

	prepared, err := materializer.Prepare(testWorkspaceRequest("member-portal-starters"))
	if err != nil {
		t.Fatal(err)
	}
	slotPath := filepath.Join(prepared.Root, "repo-alpha")
	if _, err := os.Stat(filepath.Join(slotPath, "README.md")); err != nil {
		t.Fatal(err)
	}
	descriptor := prepared.SlotDescriptors["repo_alpha"]
	if descriptor["source_alias"] != "member-portal-starters" {
		t.Fatalf("unexpected descriptor: %#v", descriptor)
	}
	if descriptor["branch_ref"] != "refs/heads/a3/work/Portal-42" {
		t.Fatalf("unexpected branch descriptor: %#v", descriptor)
	}
	if descriptor["dirty_before"] != false || descriptor["dirty_after"] != false {
		t.Fatalf("unexpected dirty descriptor: %#v", descriptor)
	}
	workspaceMetadata := readJSON(t, filepath.Join(prepared.Root, ".a3", "workspace.json"))
	if workspaceMetadata["workspace_kind"] != "ticket_workspace" || workspaceMetadata["source_ref"] != "refs/heads/a3/work/Portal-42" {
		t.Fatalf("unexpected workspace metadata: %#v", workspaceMetadata)
	}
	slotMetadata := readJSON(t, filepath.Join(slotPath, ".a3", "slot.json"))
	if slotMetadata["repo_source_root"] != sourceRoot || slotMetadata["repo_slot"] != "repo_alpha" {
		t.Fatalf("unexpected slot metadata: %#v", slotMetadata)
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
	sourceRoot := createGitSource(t, tmp, "member-portal-starters")
	if err := os.WriteFile(filepath.Join(sourceRoot, "dirty.txt"), []byte("dirty\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"member-portal-starters": sourceRoot,
		},
	}

	if _, err := materializer.Prepare(testWorkspaceRequest("member-portal-starters")); err == nil {
		t.Fatal("expected dirty source failure")
	}
}

func TestWorkspaceMaterializerRejectsMissingSlotMetadata(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "member-portal-starters")
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"member-portal-starters": sourceRoot,
		},
	}
	request := testWorkspaceRequest("member-portal-starters")
	slot := request.Slots["repo_alpha"]
	slot.SyncClass = ""
	request.Slots["repo_alpha"] = slot

	if _, err := materializer.Prepare(request); err == nil || !strings.Contains(err.Error(), "unsupported sync_class") {
		t.Fatalf("expected unsupported sync_class failure, got %v", err)
	}
}

func TestWorkspaceMaterializerRejectsNonBranchRefs(t *testing.T) {
	tmp := t.TempDir()
	sourceRoot := createGitSource(t, tmp, "member-portal-starters")
	materializer := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"member-portal-starters": sourceRoot,
		},
	}
	request := testWorkspaceRequest("member-portal-starters")
	slot := request.Slots["repo_alpha"]
	slot.Ref = "HEAD"
	request.Slots["repo_alpha"] = slot

	if _, err := materializer.Prepare(request); err == nil || !strings.Contains(err.Error(), "unsupported branch ref") {
		t.Fatalf("expected unsupported branch ref failure, got %v", err)
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
		Ref:       "refs/heads/a3/work/Portal-42",
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
	alphaHead := git(t, alphaRoot, "rev-parse", "a3/work/Portal-42")
	if err := os.WriteFile(filepath.Join(prepared.Root, "repo-alpha", "alpha.txt"), []byte("alpha\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(prepared.Root, "repo-beta", "beta.txt"), []byte("beta\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	err = PublishWorkspaceChanges(prepared, request, map[string]any{
		"success": true,
		"changed_files": map[string]any{
			"repo_alpha": []any{"alpha.txt"},
			"repo_beta":  []any{},
		},
	})

	if err == nil || !strings.Contains(err.Error(), "repo_beta changed files do not match worker result") {
		t.Fatalf("expected repo_beta changed files mismatch, got %v", err)
	}
	if head := git(t, alphaRoot, "rev-parse", "a3/work/Portal-42"); head != alphaHead {
		t.Fatalf("repo_alpha branch advanced before all slots validated: before=%s after=%s", alphaHead, head)
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
	alphaHead := git(t, alphaRoot, "rev-parse", "a3/work/Portal-42")
	if err := os.WriteFile(filepath.Join(prepared.Root, "repo-alpha", "alpha.txt"), []byte("alpha\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	prepared.SlotDescriptors["repo_beta"] = map[string]any{}

	err = executePublishPlans(prepared, []publishPlan{
		{slotName: "repo_alpha", runtimePath: filepath.Join(prepared.Root, "repo-alpha"), declared: []string{"alpha.txt"}},
		{slotName: "repo_beta", runtimePath: filepath.Join(prepared.Root, "missing-repo"), declared: []string{"beta.txt"}},
	}, "test rollback")

	if err == nil || !strings.Contains(err.Error(), "rev-parse") {
		t.Fatalf("expected publish failure after first commit, got %v", err)
	}
	if head := git(t, alphaRoot, "rev-parse", "a3/work/Portal-42"); head != alphaHead {
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
	alphaPath := filepath.Join(prepared.Root, "repo-alpha")
	if err := os.WriteFile(filepath.Join(alphaPath, "alpha.txt"), []byte("alpha\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	err = executePublishPlans(prepared, []publishPlan{
		{slotName: "repo_alpha", runtimePath: alphaPath, declared: []string{"missing.txt"}},
	}, "test rollback current")

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
	git(t, sourceRoot, "branch", "-f", "a3/work/Portal-42", "HEAD")
	git(t, sourceRoot, "branch", "a3/live", "HEAD~1")
	before := git(t, sourceRoot, "rev-parse", "refs/heads/a3/live")
	source := git(t, sourceRoot, "rev-parse", "refs/heads/a3/work/Portal-42")

	descriptor, execution := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"repo-alpha": sourceRoot,
		},
	}.Merge(MergeRequest{
		WorkspaceID: "merge-Portal-42",
		Policy:      "ff_only",
		Slots: map[string]MergeSlotRequest{
			"repo_alpha": {
				Source: WorkspaceSourceRequest{
					Kind:  "local_git",
					Alias: "repo-alpha",
				},
				SourceRef: "refs/heads/a3/work/Portal-42",
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
	if slot["merge_status"] != "merged" || slot["project_repo_mutator"] != "a3-agent" {
		t.Fatalf("missing agent merge evidence: %#v", slot)
	}
	if out := git(t, sourceRoot, "worktree", "list", "--porcelain"); strings.Contains(out, "merge-Portal-42") {
		t.Fatalf("merge worktree leaked: %s", out)
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
		WorkspaceID: "merge-Portal-42",
		Policy:      "surprising_policy",
		Slots: map[string]MergeSlotRequest{
			"repo_alpha": {
				Source: WorkspaceSourceRequest{
					Kind:  "local_git",
					Alias: "repo-alpha",
				},
				SourceRef: "refs/heads/a3/work/Portal-42",
				TargetRef: "refs/heads/a3/live",
			},
		},
	})

	if execution.Status != "failed" || !strings.Contains(string(execution.CombinedLog), "unsupported merge policy") {
		t.Fatalf("expected unsupported policy failure, got %#v", execution)
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
	git(t, sourceRoot, "branch", "-f", "a3/work/Portal-42", "HEAD")

	_, execution := WorkspaceMaterializer{
		WorkspaceRoot: filepath.Join(tmp, "agent-workspaces"),
		SourceAliases: map[string]string{
			"repo-alpha": sourceRoot,
		},
	}.Merge(MergeRequest{
		WorkspaceID: "merge-Portal-42",
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
		WorkspaceID: "merge-Portal-42",
		Policy:      "ff_only",
		Slots: map[string]MergeSlotRequest{
			"repo_alpha": {
				Source: WorkspaceSourceRequest{
					Kind:  "local_git",
					Alias: "repo-alpha",
				},
				SourceRef:    "refs/heads/a3/work/Portal-42",
				TargetRef:    "refs/heads/a3/live",
				BootstrapRef: "HEAD",
			},
			"repo_beta": {
				Source: WorkspaceSourceRequest{
					Kind:  "unsupported",
					Alias: "repo-alpha",
				},
				SourceRef: "refs/heads/a3/work/Portal-42",
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
		WorkspaceID:     "Portal-42-ticket",
		FreshnessPolicy: "reuse_if_clean_and_ref_matches",
		CleanupPolicy:   "retain_until_a3_cleanup",
		PublishPolicy: &WorkspacePublishPolicy{
			Mode:          "commit_declared_changes_on_success",
			CommitMessage: "A3 implementation update for Portal#42",
		},
		Slots: map[string]WorkspaceSlotRequest{
			"repo_alpha": {
				Source: WorkspaceSourceRequest{
					Kind:  "local_git",
					Alias: sourceAlias,
				},
				Ref:       "refs/heads/a3/work/Portal-42",
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
	git(t, sourceRoot, "branch", "a3/work/Portal-42", "HEAD")
	return sourceRoot
}

func git(t *testing.T, root string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v failed: %v: %s", args, err, out)
	}
	return string(out)
}

func gitMaybe(root string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func contains(value, needle string) bool {
	return strings.Contains(value, needle)
}
