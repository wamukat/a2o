# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe A3::Infra::LocalWorkspaceChangePublisher do
  subject(:publisher) { described_class.new }

  it "commits ticket workspace changes back to the source ref" do
    Dir.mktmpdir do |dir|
      source_root = Pathname(File.join(dir, "repo"))
      create_git_repo_source(dir, name: "repo")
      system("git", "-C", source_root.to_s, "branch", "-f", "a3/work/Portal-3050", "HEAD")

      worktree = Pathname(File.join(dir, "ticket-workspace"))
      system("git", "-C", source_root.to_s, "worktree", "add", "--force", "--detach", worktree.to_s, "refs/heads/a3/work/Portal-3050")
      FileUtils.mkdir_p(worktree.join(".a3"))
      File.write(
        worktree.join(".a3", "slot.json"),
        JSON.pretty_generate(
          "task_ref" => "Portal#3050",
          "workspace_kind" => "ticket_workspace",
          "repo_slot" => "repo_beta",
          "sync_class" => "eager",
          "source_type" => "branch_head",
          "source_ref" => "refs/heads/a3/work/Portal-3050",
          "artifact_owner_ref" => "Portal#3050",
          "artifact_owner_scope" => "task",
          "artifact_snapshot_version" => "refs/heads/a3/work/Portal-3050",
          "bootstrap_marker" => nil
        )
      )
      FileUtils.mkdir_p(worktree.join(".a3-canary"))
      File.write(worktree.join(".a3-canary", "local-live-merge-verification.md"), "- Portal#3050: implementation diff generated\n")

      run = A3::Domain::Run.new(
        ref: "run-1",
        task_ref: "Portal#3050",
        phase: :implementation,
        workspace_kind: :ticket_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :ticket_workspace,
          source_type: :branch_head,
          ref: "refs/heads/a3/work/Portal-3050",
          task_ref: "Portal#3050"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_beta],
          verification_scope: [:repo_beta],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "Portal#3050",
          owner_scope: :task,
          snapshot_version: "refs/heads/a3/work/Portal-3050"
        )
      )
      workspace = A3::Domain::PreparedWorkspace.new(
        workspace_kind: :ticket_workspace,
        root_path: Pathname(File.join(dir, "workspace-root")),
        source_descriptor: run.source_descriptor,
        slot_paths: { repo_beta: worktree }
      )
      execution = A3::Application::ExecutionResult.new(
        success: true,
        summary: "implemented",
        response_bundle: { "changed_files" => { "repo_beta" => [".a3-canary/local-live-merge-verification.md"] } }
      )

      before_head = `git -C #{source_root} rev-parse refs/heads/a3/work/Portal-3050`.strip
      result = publisher.publish(run: run, workspace: workspace, execution: execution)
      after_head = `git -C #{source_root} rev-parse refs/heads/a3/work/Portal-3050`.strip

      expect(result).to be_success
      expect(result.summary).to include("published workspace changes")
      expect(after_head).not_to eq(before_head)
      expect(`git -C #{source_root} show --stat --oneline #{after_head}`).to include("A3 direct canary update for Portal#3050")
    end
  end

  it "fails when worker changed files are not fully declared" do
    Dir.mktmpdir do |dir|
      source_root = Pathname(File.join(dir, "repo"))
      create_git_repo_source(dir, name: "repo")
      system("git", "-C", source_root.to_s, "branch", "-f", "a3/work/Portal-3051", "HEAD")

      worktree = Pathname(File.join(dir, "ticket-workspace"))
      system("git", "-C", source_root.to_s, "worktree", "add", "--force", "--detach", worktree.to_s, "refs/heads/a3/work/Portal-3051")
      FileUtils.mkdir_p(worktree.join(".a3"))
      File.write(
        worktree.join(".a3", "slot.json"),
        JSON.pretty_generate(
          "task_ref" => "Portal#3051",
          "workspace_kind" => "ticket_workspace",
          "repo_slot" => "repo_beta",
          "sync_class" => "eager",
          "source_type" => "branch_head",
          "source_ref" => "refs/heads/a3/work/Portal-3051",
          "artifact_owner_ref" => "Portal#3051",
          "artifact_owner_scope" => "task",
          "artifact_snapshot_version" => "refs/heads/a3/work/Portal-3051",
          "bootstrap_marker" => nil
        )
      )
      File.write(worktree.join("keep.txt"), "safe\n")
      File.write(worktree.join("extra.txt"), "unsafe\n")

      run = A3::Domain::Run.new(
        ref: "run-2",
        task_ref: "Portal#3051",
        phase: :implementation,
        workspace_kind: :ticket_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :ticket_workspace,
          source_type: :branch_head,
          ref: "refs/heads/a3/work/Portal-3051",
          task_ref: "Portal#3051"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_beta],
          verification_scope: [:repo_beta],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "Portal#3051",
          owner_scope: :task,
          snapshot_version: "refs/heads/a3/work/Portal-3051"
        )
      )
      workspace = A3::Domain::PreparedWorkspace.new(
        workspace_kind: :ticket_workspace,
        root_path: Pathname(File.join(dir, "workspace-root")),
        source_descriptor: run.source_descriptor,
        slot_paths: { repo_beta: worktree }
      )
      execution = A3::Application::ExecutionResult.new(
        success: true,
        summary: "implemented",
        response_bundle: { "changed_files" => { "repo_beta" => ["keep.txt"] } }
      )

      result = publisher.publish(run: run, workspace: workspace, execution: execution)

      expect(result.success?).to be(false)
      expect(result.summary).to include("worker response omitted changed_files")
      expect(result.observed_state).to eq("workspace publication failed")
      expect(`git -C #{source_root} rev-parse refs/heads/a3/work/Portal-3051`.strip).to eq(
        `git -C #{source_root} rev-parse HEAD`.strip
      )
    end
  end

  it "runs remediation commands before staging publish changes" do
    Dir.mktmpdir do |dir|
      source_root = Pathname(File.join(dir, "repo"))
      create_git_repo_source(dir, name: "repo")
      system("git", "-C", source_root.to_s, "branch", "-f", "a3/work/Portal-3052", "HEAD")

      worktree = Pathname(File.join(dir, "ticket-workspace"))
      system("git", "-C", source_root.to_s, "worktree", "add", "--force", "--detach", worktree.to_s, "refs/heads/a3/work/Portal-3052")
      FileUtils.mkdir_p(worktree.join(".a3"))
      File.write(
        worktree.join(".a3", "slot.json"),
        JSON.pretty_generate(
          "task_ref" => "Portal#3052",
          "workspace_kind" => "ticket_workspace",
          "repo_slot" => "repo_beta",
          "sync_class" => "eager",
          "source_type" => "branch_head",
          "source_ref" => "refs/heads/a3/work/Portal-3052",
          "artifact_owner_ref" => "Portal#3052",
          "artifact_owner_scope" => "task",
          "artifact_snapshot_version" => "refs/heads/a3/work/Portal-3052",
          "bootstrap_marker" => nil
        )
      )
      File.write(worktree.join("keep.txt"), "before\n")

      run = A3::Domain::Run.new(
        ref: "run-3",
        task_ref: "Portal#3052",
        phase: :implementation,
        workspace_kind: :ticket_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :ticket_workspace,
          source_type: :branch_head,
          ref: "refs/heads/a3/work/Portal-3052",
          task_ref: "Portal#3052"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_beta],
          verification_scope: [:repo_beta],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "Portal#3052",
          owner_scope: :task,
          snapshot_version: "refs/heads/a3/work/Portal-3052"
        )
      )
      workspace = A3::Domain::PreparedWorkspace.new(
        workspace_kind: :ticket_workspace,
        root_path: Pathname(File.join(dir, "workspace-root")),
        source_descriptor: run.source_descriptor,
        slot_paths: { repo_beta: worktree }
      )
      execution = A3::Application::ExecutionResult.new(
        success: true,
        summary: "implemented",
        response_bundle: { "changed_files" => { "repo_beta" => ["keep.txt"] } }
      )

      result = publisher.publish(
        run: run,
        workspace: workspace,
        execution: execution,
        remediation_commands: ["python3 - <<'PY'\nfrom pathlib import Path\nPath(\"keep.txt\").write_text(\"after\\n\", encoding=\"utf-8\")\nPY"]
      )

      expect(result).to be_success
      expect(result.summary).to include("python3 - <<'PY'")
      expect(`git -C #{source_root} show refs/heads/a3/work/Portal-3052:keep.txt`).to eq("after\n")
    end
  end

  it "discards remediation-only changes that fall outside the allowlist" do
    Dir.mktmpdir do |dir|
      source_root = Pathname(File.join(dir, "repo"))
      create_git_repo_source(dir, name: "repo")
      FileUtils.mkdir_p(source_root.join("samples"))
      File.write(source_root.join("samples", "extra.txt"), "untouched\n")
      system("git", "-C", source_root.to_s, "add", "samples/extra.txt")
      system("git", "-C", source_root.to_s, "-c", "user.name=Spec", "-c", "user.email=spec@example.com", "commit", "-m", "add tracked sample")
      system("git", "-C", source_root.to_s, "branch", "-f", "a3/work/Portal-3053", "HEAD")

      worktree = Pathname(File.join(dir, "ticket-workspace"))
      system("git", "-C", source_root.to_s, "worktree", "add", "--force", "--detach", worktree.to_s, "refs/heads/a3/work/Portal-3053")
      FileUtils.mkdir_p(worktree.join(".a3"))
      File.write(
        worktree.join(".a3", "slot.json"),
        JSON.pretty_generate(
          "task_ref" => "Portal#3053",
          "workspace_kind" => "ticket_workspace",
          "repo_slot" => "repo_beta",
          "sync_class" => "eager",
          "source_type" => "branch_head",
          "source_ref" => "refs/heads/a3/work/Portal-3053",
          "artifact_owner_ref" => "Portal#3053",
          "artifact_owner_scope" => "task",
          "artifact_snapshot_version" => "refs/heads/a3/work/Portal-3053",
          "bootstrap_marker" => nil
        )
      )
      File.write(worktree.join("keep.txt"), "before\n")

      run = A3::Domain::Run.new(
        ref: "run-4",
        task_ref: "Portal#3053",
        phase: :implementation,
        workspace_kind: :ticket_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :ticket_workspace,
          source_type: :branch_head,
          ref: "refs/heads/a3/work/Portal-3053",
          task_ref: "Portal#3053"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_beta],
          verification_scope: [:repo_beta],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "Portal#3053",
          owner_scope: :task,
          snapshot_version: "refs/heads/a3/work/Portal-3053"
        )
      )
      workspace = A3::Domain::PreparedWorkspace.new(
        workspace_kind: :ticket_workspace,
        root_path: Pathname(File.join(dir, "workspace-root")),
        source_descriptor: run.source_descriptor,
        slot_paths: { repo_beta: worktree }
      )
      execution = A3::Application::ExecutionResult.new(
        success: true,
        summary: "implemented",
        response_bundle: { "changed_files" => { "repo_beta" => ["keep.txt"] } }
      )

      result = publisher.publish(
        run: run,
        workspace: workspace,
        execution: execution,
        remediation_commands: ["python3 - <<'PY'\nfrom pathlib import Path\nPath('keep.txt').write_text('after\\n', encoding='utf-8')\nPath('samples/extra.txt').write_text('reformatted\\n', encoding='utf-8')\nPY"]
      )

      expect(result).to be_success
      expect(`git -C #{source_root} show refs/heads/a3/work/Portal-3053:keep.txt`).to eq("after\n")
      expect(`git -C #{source_root} show refs/heads/a3/work/Portal-3053:samples/extra.txt`).to eq("untouched\n")
    end
  end
end
