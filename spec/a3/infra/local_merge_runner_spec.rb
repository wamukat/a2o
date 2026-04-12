# frozen_string_literal: true

require "tmpdir"
require "shellwords"

RSpec.describe A3::Infra::LocalMergeRunner do
  subject(:runner) { described_class.new }

  it "merges the source ref into the target ref for each merge slot via temporary merge branches" do
    Dir.mktmpdir do |dir|
      repo_alpha_repo = File.join(dir, "repo-alpha")
      ui_app_repo = File.join(dir, "repo-beta")
      create_mergeable_git_repo(repo_alpha_repo)
      create_mergeable_git_repo(ui_app_repo)

      repo_alpha_slot = File.join(dir, "runtime-workspace", "repo-alpha")
      ui_app_slot = File.join(dir, "runtime-workspace", "repo-beta")
      FileUtils.mkdir_p(File.dirname(repo_alpha_slot))
      `git -C #{Shellwords.escape(repo_alpha_repo)} worktree add --detach #{Shellwords.escape(repo_alpha_slot)} refs/heads/a3/parent/A3-v2-3022`
      `git -C #{Shellwords.escape(ui_app_repo)} worktree add --detach #{Shellwords.escape(ui_app_slot)} refs/heads/a3/parent/A3-v2-3022`

      workspace = A3::Domain::PreparedWorkspace.new(
        workspace_kind: :runtime_workspace,
        root_path: File.join(dir, "runtime-workspace"),
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :integration_record,
          ref: "refs/heads/a3/parent/A3-v2-3022",
          task_ref: "A3-v2#3022"
        ),
        slot_paths: {
          repo_alpha: repo_alpha_slot,
          repo_beta: ui_app_slot
        }
      )
      plan = A3::Domain::MergePlan.new(
        task_ref: "A3-v2#3022",
        run_ref: "run-merge-1",
        merge_source: A3::Domain::MergeSource.new(source_ref: "refs/heads/a3/parent/A3-v2-3022"),
        integration_target: A3::Domain::IntegrationTarget.new(target_ref: "refs/heads/live"),
        merge_policy: :ff_only,
        merge_slots: %i[repo_alpha repo_beta]
      )

      result = runner.run(plan, workspace: workspace)

      expect(result.success?).to be(true)
      expect(`git -C #{Shellwords.escape(repo_alpha_repo)} rev-parse refs/heads/live`.strip)
        .to eq(`git -C #{Shellwords.escape(repo_alpha_repo)} rev-parse refs/heads/a3/parent/A3-v2-3022`.strip)
      expect(`git -C #{Shellwords.escape(ui_app_repo)} rev-parse refs/heads/live`.strip)
        .to eq(`git -C #{Shellwords.escape(ui_app_repo)} rev-parse refs/heads/a3/parent/A3-v2-3022`.strip)
      expect(`git -C #{Shellwords.escape(repo_alpha_repo)} show-ref --verify --quiet refs/heads/a3/merge-publication/A3-v2-3022/run-merge-1/repo_alpha; echo $?`.strip).to eq("1")
      expect(`git -C #{Shellwords.escape(ui_app_repo)} show-ref --verify --quiet refs/heads/a3/merge-publication/A3-v2-3022/run-merge-1/repo_beta; echo $?`.strip).to eq("1")
    end
  end

  it "does not publish any target ref when a later merge slot fails" do
    Dir.mktmpdir do |dir|
      repo_alpha_repo = File.join(dir, "repo-alpha")
      ui_app_repo = File.join(dir, "repo-beta")
      create_mergeable_git_repo(repo_alpha_repo)
      create_conflicting_git_repo(ui_app_repo)

      repo_alpha_live_before = `git -C #{Shellwords.escape(repo_alpha_repo)} rev-parse refs/heads/live`.strip
      ui_live_before = `git -C #{Shellwords.escape(ui_app_repo)} rev-parse refs/heads/live`.strip
      repo_alpha_parent = `git -C #{Shellwords.escape(repo_alpha_repo)} rev-parse refs/heads/a3/parent/A3-v2-3022`.strip
      ui_parent = `git -C #{Shellwords.escape(ui_app_repo)} rev-parse refs/heads/a3/parent/A3-v2-3022`.strip

      repo_alpha_slot = File.join(dir, "runtime-workspace", "repo-alpha")
      ui_app_slot = File.join(dir, "runtime-workspace", "repo-beta")
      FileUtils.mkdir_p(File.dirname(repo_alpha_slot))
      `git -C #{Shellwords.escape(repo_alpha_repo)} worktree add --detach #{Shellwords.escape(repo_alpha_slot)} refs/heads/a3/parent/A3-v2-3022`
      `git -C #{Shellwords.escape(ui_app_repo)} worktree add --detach #{Shellwords.escape(ui_app_slot)} refs/heads/a3/parent/A3-v2-3022`

      workspace = A3::Domain::PreparedWorkspace.new(
        workspace_kind: :runtime_workspace,
        root_path: File.join(dir, "runtime-workspace"),
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :integration_record,
          ref: "refs/heads/a3/parent/A3-v2-3022",
          task_ref: "A3-v2#3022"
        ),
        slot_paths: {
          repo_alpha: repo_alpha_slot,
          repo_beta: ui_app_slot
        }
      )
      plan = A3::Domain::MergePlan.new(
        task_ref: "A3-v2#3022",
        run_ref: "run-merge-1",
        merge_source: A3::Domain::MergeSource.new(source_ref: "refs/heads/a3/parent/A3-v2-3022"),
        integration_target: A3::Domain::IntegrationTarget.new(target_ref: "refs/heads/live"),
        merge_policy: :ff_only,
        merge_slots: %i[repo_alpha repo_beta]
      )

      result = runner.run(plan, workspace: workspace)

      expect(result.success?).to be(false)
      expect(`git -C #{Shellwords.escape(repo_alpha_repo)} rev-parse refs/heads/live`.strip).to eq(repo_alpha_live_before)
      expect(`git -C #{Shellwords.escape(ui_app_repo)} rev-parse refs/heads/live`.strip).to eq(ui_live_before)
      expect(`git -C #{Shellwords.escape(repo_alpha_repo)} rev-parse refs/heads/a3/parent/A3-v2-3022`.strip).to eq(repo_alpha_parent)
      expect(`git -C #{Shellwords.escape(ui_app_repo)} rev-parse refs/heads/a3/parent/A3-v2-3022`.strip).to eq(ui_parent)
    end
  end

  it "supports no_ff merge policy by creating a merge commit on the target ref" do
    Dir.mktmpdir do |dir|
      repo_alpha_repo = File.join(dir, "repo-alpha")
      create_mergeable_git_repo(repo_alpha_repo)
      slot = File.join(dir, "runtime-workspace", "repo-alpha")
      FileUtils.mkdir_p(File.dirname(slot))
      `git -C #{Shellwords.escape(repo_alpha_repo)} worktree add --detach #{Shellwords.escape(slot)} refs/heads/a3/parent/A3-v2-3022`

      workspace = A3::Domain::PreparedWorkspace.new(
        workspace_kind: :runtime_workspace,
        root_path: File.join(dir, "runtime-workspace"),
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :integration_record,
          ref: "refs/heads/a3/parent/A3-v2-3022",
          task_ref: "A3-v2#3022"
        ),
        slot_paths: { repo_alpha: slot }
      )
      live_before = `git -C #{Shellwords.escape(repo_alpha_repo)} rev-parse refs/heads/live`.strip
      plan = A3::Domain::MergePlan.new(
        task_ref: "A3-v2#3022",
        run_ref: "run-merge-1",
        merge_source: A3::Domain::MergeSource.new(source_ref: "refs/heads/a3/parent/A3-v2-3022"),
        integration_target: A3::Domain::IntegrationTarget.new(target_ref: "refs/heads/live"),
        merge_policy: :no_ff,
        merge_slots: [:repo_alpha]
      )

      result = runner.run(plan, workspace: workspace)

      expect(result.success?).to be(true)
      live_after = `git -C #{Shellwords.escape(repo_alpha_repo)} rev-parse refs/heads/live`.strip
      expect(live_after).not_to eq(live_before)
      parents = `git -C #{Shellwords.escape(repo_alpha_repo)} rev-list --parents -n 1 #{live_after}`.strip.split
      expect(parents.length).to eq(3)
      expect(`git -C #{Shellwords.escape(repo_alpha_repo)} show-ref --verify --quiet refs/heads/a3/merge-publication/A3-v2-3022/run-merge-1/repo_alpha; echo $?`.strip).to eq("1")
    end
  end

  it "supports ff_or_merge by fast-forwarding when possible" do
    Dir.mktmpdir do |dir|
      repo_alpha_repo = File.join(dir, "repo-alpha")
      create_mergeable_git_repo(repo_alpha_repo)
      slot = File.join(dir, "runtime-workspace", "repo-alpha")
      FileUtils.mkdir_p(File.dirname(slot))
      `git -C #{Shellwords.escape(repo_alpha_repo)} worktree add --detach #{Shellwords.escape(slot)} refs/heads/a3/parent/A3-v2-3022`

      workspace = A3::Domain::PreparedWorkspace.new(
        workspace_kind: :runtime_workspace,
        root_path: File.join(dir, "runtime-workspace"),
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :integration_record,
          ref: "refs/heads/a3/parent/A3-v2-3022",
          task_ref: "A3-v2#3022"
        ),
        slot_paths: { repo_alpha: slot }
      )
      plan = A3::Domain::MergePlan.new(
        task_ref: "A3-v2#3022",
        run_ref: "run-merge-1",
        merge_source: A3::Domain::MergeSource.new(source_ref: "refs/heads/a3/parent/A3-v2-3022"),
        integration_target: A3::Domain::IntegrationTarget.new(target_ref: "refs/heads/live"),
        merge_policy: :ff_or_merge,
        merge_slots: [:repo_alpha]
      )

      result = runner.run(plan, workspace: workspace)

      expect(result.success?).to be(true)
      expect(`git -C #{Shellwords.escape(repo_alpha_repo)} rev-parse refs/heads/live`.strip)
        .to eq(`git -C #{Shellwords.escape(repo_alpha_repo)} rev-parse refs/heads/a3/parent/A3-v2-3022`.strip)
    end
  end

  it "supports ff_or_merge by creating a merge commit when fast-forward is not possible" do
    Dir.mktmpdir do |dir|
      repo_alpha_repo = File.join(dir, "repo-alpha")
      create_mergeable_git_repo(repo_alpha_repo)
      live_before = `git -C #{Shellwords.escape(repo_alpha_repo)} rev-parse refs/heads/live`.strip
      `git -C #{Shellwords.escape(repo_alpha_repo)} checkout -q live`
      File.write(File.join(repo_alpha_repo, "live-only.txt"), "live-only\n")
      `git -C #{Shellwords.escape(repo_alpha_repo)} add live-only.txt`
      `git -C #{Shellwords.escape(repo_alpha_repo)} commit -q -m "Advance live branch"`
      slot = File.join(dir, "runtime-workspace", "repo-alpha")
      FileUtils.mkdir_p(File.dirname(slot))
      `git -C #{Shellwords.escape(repo_alpha_repo)} worktree add --detach #{Shellwords.escape(slot)} refs/heads/a3/parent/A3-v2-3022`

      workspace = A3::Domain::PreparedWorkspace.new(
        workspace_kind: :runtime_workspace,
        root_path: File.join(dir, "runtime-workspace"),
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :integration_record,
          ref: "refs/heads/a3/parent/A3-v2-3022",
          task_ref: "A3-v2#3022"
        ),
        slot_paths: { repo_alpha: slot }
      )
      plan = A3::Domain::MergePlan.new(
        task_ref: "A3-v2#3022",
        run_ref: "run-merge-1",
        merge_source: A3::Domain::MergeSource.new(source_ref: "refs/heads/a3/parent/A3-v2-3022"),
        integration_target: A3::Domain::IntegrationTarget.new(target_ref: "refs/heads/live"),
        merge_policy: :ff_or_merge,
        merge_slots: [:repo_alpha]
      )

      result = runner.run(plan, workspace: workspace)

      expect(result.success?).to be(true)
      live_after = `git -C #{Shellwords.escape(repo_alpha_repo)} rev-parse refs/heads/live`.strip
      expect(live_after).not_to eq(live_before)
      parents = `git -C #{Shellwords.escape(repo_alpha_repo)} rev-list --parents -n 1 #{live_after}`.strip.split
      expect(parents.length).to eq(3)
    end
  end

  it "synchronizes a clean root checkout on the target branch after publish" do
    Dir.mktmpdir do |dir|
      repo_alpha_repo = File.join(dir, "repo-alpha")
      create_mergeable_git_repo(repo_alpha_repo)
      `git -C #{Shellwords.escape(repo_alpha_repo)} checkout -q live`
      slot = File.join(dir, "runtime-workspace", "repo-alpha")
      FileUtils.mkdir_p(File.dirname(slot))
      `git -C #{Shellwords.escape(repo_alpha_repo)} worktree add --detach #{Shellwords.escape(slot)} refs/heads/a3/parent/A3-v2-3022`
      write_slot_metadata(slot, repo_source_root: repo_alpha_repo)

      workspace = A3::Domain::PreparedWorkspace.new(
        workspace_kind: :runtime_workspace,
        root_path: File.join(dir, "runtime-workspace"),
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :integration_record,
          ref: "refs/heads/a3/parent/A3-v2-3022",
          task_ref: "A3-v2#3022"
        ),
        slot_paths: { repo_alpha: slot }
      )
      plan = A3::Domain::MergePlan.new(
        task_ref: "A3-v2#3022",
        run_ref: "run-merge-1",
        merge_source: A3::Domain::MergeSource.new(source_ref: "refs/heads/a3/parent/A3-v2-3022"),
        integration_target: A3::Domain::IntegrationTarget.new(target_ref: "refs/heads/live"),
        merge_policy: :ff_only,
        merge_slots: [:repo_alpha]
      )

      result = runner.run(plan, workspace: workspace)

      expect(result.success?).to be(true)
      expect(`git -C #{Shellwords.escape(repo_alpha_repo)} status --short`.strip).to eq("")
      expect(`git -C #{Shellwords.escape(repo_alpha_repo)} rev-parse HEAD`.strip)
        .to eq(`git -C #{Shellwords.escape(repo_alpha_repo)} rev-parse refs/heads/live`.strip)
    end
  end

  it "bootstraps a missing parent integration ref from live before merging" do
    Dir.mktmpdir do |dir|
      repo_alpha_repo = File.join(dir, "repo-alpha")
      create_work_branch_git_repo(repo_alpha_repo)
      slot = File.join(dir, "runtime-workspace", "repo-alpha")
      FileUtils.mkdir_p(File.dirname(slot))
      `git -C #{Shellwords.escape(repo_alpha_repo)} worktree add --detach #{Shellwords.escape(slot)} refs/heads/a3/work/A3-v2-3025`

      workspace = A3::Domain::PreparedWorkspace.new(
        workspace_kind: :runtime_workspace,
        root_path: File.join(dir, "runtime-workspace"),
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :branch_head,
          ref: "refs/heads/a3/work/A3-v2-3025",
          task_ref: "A3-v2#3025"
        ),
        slot_paths: { repo_alpha: slot }
      )
      plan = A3::Domain::MergePlan.new(
        task_ref: "A3-v2#3025",
        run_ref: "run-merge-1",
        merge_source: A3::Domain::MergeSource.new(source_ref: "refs/heads/a3/work/A3-v2-3025"),
        integration_target: A3::Domain::IntegrationTarget.new(
          target_ref: "refs/heads/a3/parent/A3-v2-3022",
          bootstrap_ref: "refs/heads/live"
        ),
        merge_policy: :ff_only,
        merge_slots: [:repo_alpha]
      )

      expect(`git -C #{Shellwords.escape(repo_alpha_repo)} show-ref --verify --quiet refs/heads/a3/parent/A3-v2-3022; echo $?`.strip).to eq("1")

      result = runner.run(plan, workspace: workspace)

      expect(result.success?).to be(true)
      expect(`git -C #{Shellwords.escape(repo_alpha_repo)} rev-parse refs/heads/a3/parent/A3-v2-3022`.strip)
        .to eq(`git -C #{Shellwords.escape(repo_alpha_repo)} rev-parse refs/heads/a3/work/A3-v2-3025`.strip)
    end
  end

  it "keeps the parent-owned workspace slot synchronized after child merge publication" do
    Dir.mktmpdir do |dir|
      repo_alpha_repo = File.join(dir, "repo-alpha")
      create_work_branch_git_repo(repo_alpha_repo)
      parent_slot = File.join(dir, "workspaces", "Portal-134", "runtime_workspace", "repo-alpha")
      child_slot = File.join(dir, "workspaces", "Portal-134", "children", "Portal-135", "runtime_workspace", "repo-alpha")
      FileUtils.mkdir_p(File.dirname(parent_slot))
      FileUtils.mkdir_p(File.dirname(child_slot))
      `git -C #{Shellwords.escape(repo_alpha_repo)} branch a3/parent/Portal-134 live`
      `git -C #{Shellwords.escape(repo_alpha_repo)} worktree add --detach #{Shellwords.escape(parent_slot)} refs/heads/a3/parent/Portal-134`
      `git -C #{Shellwords.escape(repo_alpha_repo)} worktree add --detach #{Shellwords.escape(child_slot)} refs/heads/a3/work/A3-v2-3025`
      parent_before = `git -C #{Shellwords.escape(parent_slot)} rev-parse HEAD`.strip
      child_head = `git -C #{Shellwords.escape(child_slot)} rev-parse HEAD`.strip

      workspace = A3::Domain::PreparedWorkspace.new(
        workspace_kind: :runtime_workspace,
        root_path: File.join(dir, "workspaces", "Portal-134", "children", "Portal-135", "runtime_workspace"),
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :branch_head,
          ref: "refs/heads/a3/work/A3-v2-3025",
          task_ref: "Portal#135"
        ),
        slot_paths: { repo_alpha: child_slot }
      )
      plan = A3::Domain::MergePlan.new(
        task_ref: "Portal#135",
        run_ref: "run-merge-1",
        merge_source: A3::Domain::MergeSource.new(source_ref: "refs/heads/a3/work/A3-v2-3025"),
        integration_target: A3::Domain::IntegrationTarget.new(
          target_ref: "refs/heads/a3/parent/Portal-134",
          bootstrap_ref: "refs/heads/live"
        ),
        merge_policy: :ff_only,
        merge_slots: [:repo_alpha]
      )

      result = runner.run(plan, workspace: workspace)

      expect(result.success?).to be(true)
      expect(parent_before).not_to eq(child_head)
      expect(`git -C #{Shellwords.escape(parent_slot)} rev-parse HEAD`.strip).to eq(child_head)
      expect(`git -C #{Shellwords.escape(repo_alpha_repo)} rev-parse refs/heads/a3/parent/Portal-134`.strip).to eq(child_head)
    end
  end

  it "bootstraps a missing parent integration ref from a configured live target branch" do
    Dir.mktmpdir do |dir|
      repo_alpha_repo = File.join(dir, "repo-alpha")
      create_work_branch_git_repo(repo_alpha_repo)
      `git -C #{Shellwords.escape(repo_alpha_repo)} branch -m live feature/prototype`
      slot = File.join(dir, "runtime-workspace", "repo-alpha")
      FileUtils.mkdir_p(File.dirname(slot))
      `git -C #{Shellwords.escape(repo_alpha_repo)} worktree add --detach #{Shellwords.escape(slot)} refs/heads/a3/work/A3-v2-3025`

      workspace = A3::Domain::PreparedWorkspace.new(
        workspace_kind: :runtime_workspace,
        root_path: File.join(dir, "runtime-workspace"),
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :branch_head,
          ref: "refs/heads/a3/work/A3-v2-3025",
          task_ref: "A3-v2#3025"
        ),
        slot_paths: { repo_alpha: slot }
      )
      plan = A3::Domain::MergePlan.new(
        task_ref: "A3-v2#3025",
        run_ref: "run-merge-1",
        merge_source: A3::Domain::MergeSource.new(source_ref: "refs/heads/a3/work/A3-v2-3025"),
        integration_target: A3::Domain::IntegrationTarget.new(
          target_ref: "refs/heads/a3/parent/A3-v2-3022",
          bootstrap_ref: "refs/heads/feature/prototype"
        ),
        merge_policy: :ff_only,
        merge_slots: [:repo_alpha]
      )

      expect(`git -C #{Shellwords.escape(repo_alpha_repo)} show-ref --verify --quiet refs/heads/a3/parent/A3-v2-3022; echo $?`.strip).to eq("1")

      result = runner.run(plan, workspace: workspace)

      expect(result.success?).to be(true)
      expect(`git -C #{Shellwords.escape(repo_alpha_repo)} rev-parse refs/heads/a3/parent/A3-v2-3022`.strip)
        .to eq(`git -C #{Shellwords.escape(repo_alpha_repo)} rev-parse refs/heads/a3/work/A3-v2-3025`.strip)
    end
  end

  it "fails fast when bootstrapping a parent integration ref without an explicit bootstrap ref" do
    Dir.mktmpdir do |dir|
      repo_alpha_repo = File.join(dir, "repo-alpha")
      create_work_branch_git_repo(repo_alpha_repo)
      slot = File.join(dir, "runtime-workspace", "repo-alpha")
      FileUtils.mkdir_p(File.dirname(slot))
      `git -C #{Shellwords.escape(repo_alpha_repo)} worktree add --detach #{Shellwords.escape(slot)} refs/heads/a3/work/A3-v2-3025`

      workspace = A3::Domain::PreparedWorkspace.new(
        workspace_kind: :runtime_workspace,
        root_path: File.join(dir, "runtime-workspace"),
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :branch_head,
          ref: "refs/heads/a3/work/A3-v2-3025",
          task_ref: "A3-v2#3025"
        ),
        slot_paths: { repo_alpha: slot }
      )
      plan = A3::Domain::MergePlan.new(
        task_ref: "A3-v2#3025",
        run_ref: "run-merge-1",
        merge_source: A3::Domain::MergeSource.new(source_ref: "refs/heads/a3/work/A3-v2-3025"),
        integration_target: A3::Domain::IntegrationTarget.new(
          target_ref: "refs/heads/a3/parent/A3-v2-3022"
        ),
        merge_policy: :ff_only,
        merge_slots: [:repo_alpha]
      )

      expect { runner.run(plan, workspace: workspace) }
        .to raise_error(A3::Domain::ConfigurationError, "missing bootstrap_ref for refs/heads/a3/parent/A3-v2-3022")
    end
  end

  it "surfaces rollback failures in diagnostics when publish rollback cannot restore a prior slot" do
    workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: "/tmp/a3-v2/runtime-workspace",
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a3/parent/A3-v2-3022",
        task_ref: "A3-v2#3022"
      ),
      slot_paths: {
        repo_alpha: Pathname("/tmp/a3-v2/runtime-workspace/repo-alpha"),
        repo_beta: Pathname("/tmp/a3-v2/runtime-workspace/repo-beta")
      }
    )
    plan = A3::Domain::MergePlan.new(
      task_ref: "A3-v2#3022",
      run_ref: "run-merge-1",
      merge_source: A3::Domain::MergeSource.new(source_ref: "refs/heads/a3/parent/A3-v2-3022"),
      integration_target: A3::Domain::IntegrationTarget.new(target_ref: "refs/heads/live"),
      merge_policy: :ff_only,
      merge_slots: %i[repo_alpha repo_beta]
    )

    allow(runner).to receive(:rev_parse).and_return("old1", "merged1", "old2", "merged2")
    allow(runner).to receive(:run_git).and_return(
      { success: true, stdout: "", stderr: "", command: "checkout-temp1", summary: "ok" },
      { success: true, stdout: "", stderr: "", command: "merge1", summary: "ok" },
      { success: true, stdout: "", stderr: "", command: "detach1", summary: "ok" },
      { success: true, stdout: "", stderr: "", command: "checkout-temp2", summary: "ok" },
      { success: true, stdout: "", stderr: "", command: "merge2", summary: "ok" },
      { success: true, stdout: "", stderr: "", command: "detach2", summary: "ok" },
      { success: true, stdout: "", stderr: "", command: "update1", summary: "ok" },
      { success: false, stdout: "", stderr: "publish failed", command: "update2", summary: "publish failed" },
      { success: false, stdout: "", stderr: "rollback failed", command: "rollback1", summary: "rollback failed" },
      { success: true, stdout: "", stderr: "", command: "cleanup1", summary: "ok" },
      { success: true, stdout: "", stderr: "", command: "cleanup2", summary: "ok" }
    )

    result = runner.run(plan, workspace: workspace)

    expect(result.success?).to be(false)
    expect(result.diagnostics.fetch("rollback_failures")).to eq(
      [
        {
          success: false,
          stdout: "",
          stderr: "rollback failed",
          command: "rollback1",
          summary: "rollback failed",
          "slot" => "repo_alpha"
        }
      ]
    )
  end

  it "cleans temporary refs when root checkout synchronization fails after publish" do
    workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: "/tmp/a3-v2/runtime-workspace",
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a3/parent/A3-v2-3022",
        task_ref: "A3-v2#3022"
      ),
      slot_paths: {
        repo_alpha: Pathname("/tmp/a3-v2/runtime-workspace/repo-alpha")
      }
    )
    plan = A3::Domain::MergePlan.new(
      task_ref: "A3-v2#3022",
      run_ref: "run-merge-1",
      merge_source: A3::Domain::MergeSource.new(source_ref: "refs/heads/a3/parent/A3-v2-3022"),
      integration_target: A3::Domain::IntegrationTarget.new(target_ref: "refs/heads/live"),
      merge_policy: :ff_only,
      merge_slots: [:repo_alpha]
    )

    allow(runner).to receive(:root_sync_metadata).and_return({repo_root: "/tmp/a3-v2/repo-alpha"})
    allow(runner).to receive(:rev_parse).and_return("old1", "merged1")
    allow(runner).to receive(:run_git).and_return(
      { success: true, stdout: "", stderr: "", command: "checkout-temp1", summary: "ok" },
      { success: true, stdout: "", stderr: "", command: "merge1", summary: "ok" },
      { success: true, stdout: "", stderr: "", command: "detach1", summary: "ok" },
      { success: true, stdout: "", stderr: "", command: "update1", summary: "ok" },
      { success: false, stdout: "", stderr: "reset failed", command: "reset", summary: "reset failed" },
      { success: true, stdout: "", stderr: "", command: "cleanup1", summary: "ok" }
    )

    result = runner.run(plan, workspace: workspace)

    expect(result.success?).to be(false)
    expect(result.observed_state).to eq("root repository sync failed")
    expect(runner).to have_received(:run_git).with(Pathname("/tmp/a3-v2/runtime-workspace/repo-alpha"), "update-ref", "-d", "refs/heads/a3/merge-publication/A3-v2-3022/run-merge-1/repo_alpha")
  end

  it "surfaces temporary ref cleanup failures after publish" do
    workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: "/tmp/a3-v2/runtime-workspace",
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a3/parent/A3-v2-3022",
        task_ref: "A3-v2#3022"
      ),
      slot_paths: {
        repo_alpha: Pathname("/tmp/a3-v2/runtime-workspace/repo-alpha")
      }
    )
    plan = A3::Domain::MergePlan.new(
      task_ref: "A3-v2#3022",
      run_ref: "run-merge-1",
      merge_source: A3::Domain::MergeSource.new(source_ref: "refs/heads/a3/parent/A3-v2-3022"),
      integration_target: A3::Domain::IntegrationTarget.new(target_ref: "refs/heads/live"),
      merge_policy: :ff_only,
      merge_slots: [:repo_alpha]
    )

    allow(runner).to receive(:root_sync_metadata).and_return(nil)
    allow(runner).to receive(:rev_parse).and_return("old1", "merged1")
    allow(runner).to receive(:run_git).and_return(
      { success: true, stdout: "", stderr: "", command: "checkout-temp1", summary: "ok" },
      { success: true, stdout: "", stderr: "", command: "merge1", summary: "ok" },
      { success: true, stdout: "", stderr: "", command: "detach1", summary: "ok" },
      { success: true, stdout: "", stderr: "", command: "update1", summary: "ok" },
      { success: false, stdout: "", stderr: "cleanup failed", command: "cleanup1", summary: "cleanup failed" }
    )

    result = runner.run(plan, workspace: workspace)

    expect(result.success?).to be(false)
    expect(result.observed_state).to eq("merge publication cleanup failed")
    expect(result.diagnostics.fetch("cleanup_failures")).to eq(
      [
        {
          success: false,
          stdout: "",
          stderr: "cleanup failed",
          command: "cleanup1",
          summary: "cleanup failed",
          "slot" => "repo_alpha",
          "temp_ref" => "refs/heads/a3/merge-publication/A3-v2-3022/run-merge-1/repo_alpha"
        }
      ]
    )
  end

  it "returns a blocked execution result when a merge slot is missing" do
    workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: "/tmp/a3-v2/workspaces/A3-v2-3022/runtime_workspace",
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a3/parent/A3-v2-3022",
        task_ref: "A3-v2#3022"
      ),
      slot_paths: {}
    )
    plan = A3::Domain::MergePlan.new(
      task_ref: "A3-v2#3022",
      run_ref: "run-merge-1",
      merge_source: A3::Domain::MergeSource.new(source_ref: "refs/heads/a3/parent/A3-v2-3022"),
      integration_target: A3::Domain::IntegrationTarget.new(target_ref: "refs/heads/live"),
      merge_policy: :ff_only,
      merge_slots: [:repo_alpha]
    )

    result = runner.run(plan, workspace: workspace)

    expect(result.success?).to be(false)
    expect(result.observed_state).to eq("missing merge slot")
  end

  def create_mergeable_git_repo(repo_dir)
    FileUtils.mkdir_p(repo_dir)
    Dir.chdir(repo_dir) do
      system("git", "init", "-q")
      system("git", "config", "user.name", "A3 Test")
      system("git", "config", "user.email", "a3-test@example.com")
      File.write("README.md", "base\n")
      system("git", "add", "README.md")
      system("git", "commit", "-q", "-m", "base")
      system("git", "branch", "live")
      system("git", "checkout", "-q", "-b", "a3/parent/A3-v2-3022")
      File.write("README.md", "merged\n")
      system("git", "commit", "-qam", "parent result")
      system("git", "checkout", "-q", "--detach")
    end
  end

  def create_conflicting_git_repo(repo_dir)
    FileUtils.mkdir_p(repo_dir)
    Dir.chdir(repo_dir) do
      system("git", "init", "-q")
      system("git", "config", "user.name", "A3 Test")
      system("git", "config", "user.email", "a3-test@example.com")
      File.write("README.md", "base\n")
      system("git", "add", "README.md")
      system("git", "commit", "-q", "-m", "base")
      system("git", "branch", "live")
      system("git", "checkout", "-q", "-b", "a3/parent/A3-v2-3022")
      File.write("README.md", "parent version\n")
      system("git", "commit", "-qam", "parent result")
      system("git", "checkout", "-q", "live")
      File.write("README.md", "live version\n")
      system("git", "commit", "-qam", "live diverged")
      system("git", "checkout", "-q", "--detach")
    end
  end

  def create_work_branch_git_repo(repo_dir)
    FileUtils.mkdir_p(repo_dir)
    Dir.chdir(repo_dir) do
      system("git", "init", "-q")
      system("git", "config", "user.name", "A3 Test")
      system("git", "config", "user.email", "a3-test@example.com")
      File.write("README.md", "base\n")
      system("git", "add", "README.md")
      system("git", "commit", "-q", "-m", "base")
      system("git", "branch", "live")
      system("git", "checkout", "-q", "-b", "a3/work/A3-v2-3025")
      File.write("README.md", "child change\n")
      system("git", "commit", "-qam", "child result")
      system("git", "checkout", "-q", "--detach")
    end
  end

  def write_slot_metadata(slot_path, repo_source_root:)
    metadata_dir = File.join(slot_path, ".a3")
    FileUtils.mkdir_p(metadata_dir)
    File.write(
      File.join(metadata_dir, "slot.json"),
      JSON.pretty_generate(
        {
          "repo_source_root" => repo_source_root
        }
      )
    )
  end
end
