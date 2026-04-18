# frozen_string_literal: true

require "json"
require "tmpdir"

RSpec.describe A3::Infra::LocalWorkspaceProvisioner do
  let(:tmpdir) { Dir.mktmpdir("a3-v2-workspace") }

  after do
    FileUtils.remove_entry(tmpdir)
  end

  it "creates a fixed-slot workspace with metadata for the source descriptor" do
    repo_sources = create_repo_sources(tmpdir)
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha]
    )
    workspace_plan = A3::Domain::WorkspacePlan.new(
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "abc123",
        task_ref: task.ref
      ),
      slot_requirements: [
        A3::Domain::SlotRequirement.new(repo_slot: :repo_alpha, sync_class: :eager),
        A3::Domain::SlotRequirement.new(repo_slot: :repo_beta, sync_class: :lazy_but_guaranteed)
      ]
    )

    provisioner = described_class.new(base_dir: tmpdir, repo_sources: repo_sources)

    workspace = provisioner.call(
      task: task,
      workspace_plan: workspace_plan,
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :task,
        snapshot_version: "abc123"
      ),
      bootstrap_marker: "workspace-hook:v1"
    )

    expect(workspace.workspace_kind).to eq(:runtime_workspace)
    expect(workspace.root_path).to exist
    expect(workspace.slot_paths.fetch(:repo_alpha)).to exist
    expect(workspace.slot_paths.fetch(:repo_beta)).to exist
    expect(workspace.slot_paths.fetch(:repo_alpha).join(".a3", "slot.json")).to exist
    expect(workspace.slot_paths.fetch(:repo_beta).join(".a3", "slot.json")).to exist
    expect(workspace.slot_paths.fetch(:repo_alpha).join("README.md").read).to eq("repo_alpha source\n")
    expect(workspace.slot_paths.fetch(:repo_beta).join("README.md").read).to eq("repo_beta source\n")
    expect(workspace.slot_paths.fetch(:repo_alpha).join(".a3", "materialized.json")).to exist
    expect(workspace.slot_paths.fetch(:repo_beta).join(".a3", "materialized.json")).to exist
    expect(workspace.slot_paths.fetch(:repo_alpha).join(".git", "HEAD").read).to eq("abc123\n")
    expect(workspace.slot_paths.fetch(:repo_beta).join(".git", "HEAD").read).to eq("abc123\n")

    metadata_path = workspace.root_path.join(".a3", "workspace.json")
    metadata = JSON.parse(metadata_path.read)
    expect(metadata).to include(
      "task_ref" => "A3-v2#3025",
      "workspace_kind" => "runtime_workspace",
      "source_type" => "detached_commit",
      "source_ref" => "abc123"
    )
    expect(metadata.fetch("slot_requirements")).to contain_exactly(
      { "repo_slot" => "repo_alpha", "sync_class" => "eager" },
      { "repo_slot" => "repo_beta", "sync_class" => "lazy_but_guaranteed" }
    )
    slot_metadata = JSON.parse(workspace.slot_paths.fetch(:repo_alpha).join(".a3", "slot.json").read)
    expect(slot_metadata).to include(
      "repo_source_root" => repo_sources.fetch(:repo_alpha),
      "artifact_owner_ref" => "A3-v2#3022",
      "artifact_owner_scope" => "task",
      "artifact_snapshot_version" => "abc123",
      "bootstrap_marker" => "workspace-hook:v1"
    )
  end

  it "skips generated local artifacts when copying non-git repo sources" do
    repo_sources = create_repo_sources(tmpdir, slots: [:repo_alpha])
    source_root = Pathname(repo_sources.fetch(:repo_alpha))
    source_root.join("src").mkpath
    source_root.join("src", "App.java").write("class App {}\n")
    source_root.join(".work", "a3", "state.json").tap do |path|
      path.dirname.mkpath
      path.write("{}\n")
    end
    source_root.join("target", "classes").mkpath
    source_root.join("node_modules", ".bin").mkpath
    source_root.join("module-a", "target").mkpath
    source_root.join("module-a", "README.md").tap do |path|
      path.dirname.mkpath
      path.write("module\n")
    end
    task = A3::Domain::Task.new(
      ref: "A3-v2#3026",
      kind: :child,
      edit_scope: [:repo_alpha]
    )
    workspace_plan = A3::Domain::WorkspacePlan.new(
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "abc123",
        task_ref: task.ref
      ),
      slot_requirements: [
        A3::Domain::SlotRequirement.new(repo_slot: :repo_alpha, sync_class: :eager)
      ]
    )
    provisioner = described_class.new(base_dir: tmpdir, repo_sources: repo_sources)

    workspace = provisioner.call(
      task: task,
      workspace_plan: workspace_plan,
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :task,
        snapshot_version: "abc123"
      ),
      bootstrap_marker: "workspace-hook:v1"
    )

    slot_path = workspace.slot_paths.fetch(:repo_alpha)
    expect(slot_path.join("README.md").read).to eq("repo_alpha source\n")
    expect(slot_path.join("src", "App.java")).to exist
    expect(slot_path.join("module-a", "README.md")).to exist
    expect(slot_path.join(".work")).not_to exist
    expect(slot_path.join("target")).not_to exist
    expect(slot_path.join("node_modules")).not_to exist
    expect(slot_path.join("module-a", "target")).not_to exist
  end

  it "re-materializes stale slot metadata when source freshness mismatches" do
    repo_sources = create_repo_sources(tmpdir, slots: [:repo_alpha])
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha]
    )
    workspace_plan = A3::Domain::WorkspacePlan.new(
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "fresh-456",
        task_ref: task.ref
      ),
      slot_requirements: [
        A3::Domain::SlotRequirement.new(repo_slot: :repo_alpha, sync_class: :eager)
      ]
    )
    provisioner = described_class.new(base_dir: tmpdir, repo_sources: repo_sources)
    stale_slot = Pathname(tmpdir).join("workspaces", "A3-v2-3025", "runtime_workspace", "repo-alpha")
    FileUtils.mkdir_p(stale_slot.join(".a3"))
    stale_slot.join("stale.txt").write("obsolete")
    stale_slot.join(".a3", "slot.json").write(
      JSON.pretty_generate(
        "task_ref" => "A3-v2#3025",
        "workspace_kind" => "runtime_workspace",
        "repo_slot" => "repo_alpha",
        "sync_class" => "eager",
        "source_type" => "detached_commit",
        "source_ref" => "stale-123"
      )
    )

    workspace = provisioner.call(
      task: task,
      workspace_plan: workspace_plan,
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :task,
        snapshot_version: "fresh-456"
      ),
      bootstrap_marker: "workspace-hook:v2"
    )

    slot_path = workspace.slot_paths.fetch(:repo_alpha)
    slot_metadata = JSON.parse(slot_path.join(".a3", "slot.json").read)
    expect(slot_metadata).to include(
      "source_ref" => "fresh-456",
      "sync_class" => "eager",
      "artifact_snapshot_version" => "fresh-456",
      "bootstrap_marker" => "workspace-hook:v2"
    )
    expect(slot_path.join("stale.txt")).not_to exist
  end

  it "re-materializes when metadata matches but materialized content marker is missing" do
    repo_sources = create_repo_sources(tmpdir, slots: [:repo_alpha])
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha]
    )
    workspace_plan = A3::Domain::WorkspacePlan.new(
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "fresh-789",
        task_ref: task.ref
      ),
      slot_requirements: [
        A3::Domain::SlotRequirement.new(repo_slot: :repo_alpha, sync_class: :eager)
      ]
    )
    provisioner = described_class.new(base_dir: tmpdir, repo_sources: repo_sources)
    slot_path = Pathname(tmpdir).join("workspaces", "A3-v2-3025", "runtime_workspace", "repo-alpha")
    FileUtils.mkdir_p(slot_path.join(".a3"))
    slot_path.join("corrupt.txt").write("not a real checkout")
    slot_path.join(".a3", "slot.json").write(
      JSON.pretty_generate(
        "task_ref" => "A3-v2#3025",
        "workspace_kind" => "runtime_workspace",
        "repo_slot" => "repo_alpha",
        "sync_class" => "eager",
        "source_type" => "detached_commit",
        "source_ref" => "fresh-789",
        "artifact_owner_ref" => "A3-v2#3022",
        "artifact_owner_scope" => "task",
        "artifact_snapshot_version" => "fresh-789",
        "bootstrap_marker" => "workspace-hook:v3"
      )
    )

    workspace = provisioner.call(
      task: task,
      workspace_plan: workspace_plan,
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :task,
        snapshot_version: "fresh-789"
      ),
      bootstrap_marker: "workspace-hook:v3"
    )

    materialized = JSON.parse(workspace.slot_paths.fetch(:repo_alpha).join(".a3", "materialized.json").read)
    expect(materialized).to include(
      "source_ref" => "fresh-789",
      "source_type" => "detached_commit"
    )
    expect(workspace.slot_paths.fetch(:repo_alpha).join(".git", "HEAD").read).to eq("fresh-789\n")
    expect(workspace.slot_paths.fetch(:repo_alpha).join("corrupt.txt")).not_to exist
  end

  it "re-materializes when git head is missing even if metadata matches" do
    repo_sources = create_repo_sources(tmpdir, slots: [:repo_alpha])
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha]
    )
    workspace_plan = A3::Domain::WorkspacePlan.new(
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "expected-head",
        task_ref: task.ref
      ),
      slot_requirements: [
        A3::Domain::SlotRequirement.new(repo_slot: :repo_alpha, sync_class: :eager)
      ]
    )
    provisioner = described_class.new(base_dir: tmpdir, repo_sources: repo_sources)
    slot_path = Pathname(tmpdir).join("workspaces", "A3-v2-3025", "runtime_workspace", "repo-alpha")
    FileUtils.mkdir_p(slot_path.join(".a3"))
    slot_path.join(".a3", "slot.json").write(
      JSON.pretty_generate(
        "task_ref" => "A3-v2#3025",
        "workspace_kind" => "runtime_workspace",
        "repo_slot" => "repo_alpha",
        "sync_class" => "eager",
        "source_type" => "detached_commit",
        "source_ref" => "expected-head",
        "artifact_owner_ref" => "A3-v2#3022",
        "artifact_owner_scope" => "task",
        "artifact_snapshot_version" => "expected-head",
        "bootstrap_marker" => "workspace-hook:v4"
      )
    )
    slot_path.join(".a3", "materialized.json").write(
      JSON.pretty_generate(
        "workspace_kind" => "runtime_workspace",
        "source_type" => "detached_commit",
        "source_ref" => "expected-head"
      )
    )

    workspace = provisioner.call(
      task: task,
      workspace_plan: workspace_plan,
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :task,
        snapshot_version: "expected-head"
      ),
      bootstrap_marker: "workspace-hook:v4"
    )

    expect(workspace.slot_paths.fetch(:repo_alpha).join(".git", "HEAD").read).to eq("expected-head\n")
  end

  it "fails fast when a required repo source is not configured" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha]
    )
    workspace_plan = A3::Domain::WorkspacePlan.new(
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "abc123",
        task_ref: task.ref
      ),
      slot_requirements: [
        A3::Domain::SlotRequirement.new(repo_slot: :repo_alpha, sync_class: :eager)
      ]
    )

    provisioner = described_class.new(base_dir: tmpdir, repo_sources: {})

    expect do
      provisioner.call(
        task: task,
        workspace_plan: workspace_plan,
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "A3-v2#3022",
          owner_scope: :task,
          snapshot_version: "abc123"
        ),
        bootstrap_marker: "workspace-hook:v1"
      )
    end.to raise_error(A3::Domain::ConfigurationError, /repo source/)
  end

  it "materializes git repo sources as worktrees when the repo source is a git repository" do
    head_sha = create_git_repo_source(
      tmpdir,
      name: "repo-alpha",
      file_name: "README.md",
      file_content: "git-backed repo-alpha\n"
    )
    repo_sources = {
      repo_alpha: File.join(tmpdir, "repo-alpha")
    }
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha]
    )
    workspace_plan = A3::Domain::WorkspacePlan.new(
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: head_sha,
        task_ref: task.ref
      ),
      slot_requirements: [
        A3::Domain::SlotRequirement.new(repo_slot: :repo_alpha, sync_class: :eager)
      ]
    )

    provisioner = described_class.new(base_dir: tmpdir, repo_sources: repo_sources)

    workspace = provisioner.call(
      task: task,
      workspace_plan: workspace_plan,
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :task,
        snapshot_version: head_sha
      ),
      bootstrap_marker: "workspace-hook:git"
    )

    slot_path = workspace.slot_paths.fetch(:repo_alpha)
    expect(slot_path.join("README.md").read).to eq("git-backed repo-alpha\n")
    expect(`git -C #{slot_path} rev-parse HEAD`.strip).to eq(head_sha)
  end

  it "quarantines terminal git-backed workspaces without leaving source worktree residue" do
    head_sha = create_git_repo_source(
      tmpdir,
      name: "repo-alpha",
      file_name: "README.md",
      file_content: "git-backed repo-alpha\n"
    )
    repo_dir = File.join(tmpdir, "repo-alpha")
    repo_sources = {
      repo_alpha: repo_dir
    }
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha]
    )
    workspace_plan = A3::Domain::WorkspacePlan.new(
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: head_sha,
        task_ref: task.ref
      ),
      slot_requirements: [
        A3::Domain::SlotRequirement.new(repo_slot: :repo_alpha, sync_class: :eager)
      ]
    )

    provisioner = described_class.new(base_dir: tmpdir, repo_sources: repo_sources)
    workspace = provisioner.call(
      task: task,
      workspace_plan: workspace_plan,
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :task,
        snapshot_version: head_sha
      ),
      bootstrap_marker: "workspace-hook:git"
    )
    slot_path = workspace.slot_paths.fetch(:repo_alpha)

    quarantine_path = provisioner.quarantine_task(task_ref: task.ref)

    expect(Pathname(quarantine_path)).to exist
    expect(Pathname(quarantine_path).join("runtime_workspace", "repo-alpha", "README.md").read).to eq("git-backed repo-alpha\n")
    expect(workspace.root_path).not_to exist
    worktree_list = `git -C #{repo_dir} worktree list --porcelain`
    expect(worktree_list).not_to include(slot_path.to_s)
  end

  it "quarantines mixed workspaces with symlinked non-git entries after removing git worktree slots" do
    head_sha = create_git_repo_source(
      tmpdir,
      name: "repo-alpha",
      file_name: "README.md",
      file_content: "git-backed repo-alpha\n"
    )
    repo_sources = {
      repo_alpha: File.join(tmpdir, "repo-alpha"),
      repo_beta: File.join(tmpdir, "repo-beta")
    }
    FileUtils.mkdir_p(repo_sources.fetch(:repo_beta))
    Pathname(repo_sources.fetch(:repo_beta)).join("README.md").write("plain repo-beta\n")

    task = A3::Domain::Task.new(
      ref: "Sample#3140",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta]
    )
    workspace_plan = A3::Domain::WorkspacePlan.new(
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: head_sha,
        task_ref: task.ref
      ),
      slot_requirements: [
        A3::Domain::SlotRequirement.new(repo_slot: :repo_alpha, sync_class: :eager),
        A3::Domain::SlotRequirement.new(repo_slot: :repo_beta, sync_class: :eager)
      ]
    )

    provisioner = described_class.new(base_dir: tmpdir, repo_sources: repo_sources)
    workspace = provisioner.call(
      task: task,
      workspace_plan: workspace_plan,
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :parent,
        snapshot_version: head_sha
      ),
      bootstrap_marker: "workspace-hook:mixed"
    )
    node_bin = workspace.root_path.join("repo-beta", "node_modules", ".bin")
    FileUtils.mkdir_p(node_bin)
    File.symlink("../tool", node_bin.join("tool"))

    quarantine_path = provisioner.quarantine_task(task_ref: task.ref)

    expect(Pathname(quarantine_path)).to exist
    expect(Pathname(quarantine_path).join("runtime_workspace", "repo-beta", "node_modules", ".bin", "tool")).to be_symlink
    expect(workspace.root_path).not_to exist
  end

  it "cleans selected workspace scopes while keeping quarantine untouched by default" do
    task_root = Pathname(tmpdir).join("workspaces", "A3-v2-3025")
    ticket_path = task_root.join("ticket_workspace")
    runtime_path = task_root.join("runtime_workspace")
    quarantine_path = Pathname(tmpdir).join("quarantine", "A3-v2-3025")
    FileUtils.mkdir_p(ticket_path)
    FileUtils.mkdir_p(runtime_path)
    FileUtils.mkdir_p(quarantine_path)

    provisioner = described_class.new(base_dir: tmpdir, repo_sources: {})
    cleaned_paths = provisioner.cleanup_task(
      task_ref: "A3-v2#3025",
      scopes: %i[ticket_workspace runtime_workspace],
      dry_run: false
    )

    expect(cleaned_paths).to contain_exactly(ticket_path.to_s, runtime_path.to_s)
    expect(task_root).not_to exist
    expect(quarantine_path).to exist
  end

  it "cleans a parent-bound child workspace by exact parent ref" do
    parent_root = Pathname(tmpdir).join("workspaces", "Sample-201-parent")
    intended_child = parent_root.join("children", "Sample-202", "ticket_workspace")
    other_child = Pathname(tmpdir).join("workspaces", "Sample-999-parent", "children", "Sample-202", "ticket_workspace")
    FileUtils.mkdir_p(intended_child)
    FileUtils.mkdir_p(other_child)

    provisioner = described_class.new(base_dir: tmpdir, repo_sources: {})
    cleaned_paths = provisioner.cleanup_task(
      task_ref: "Sample#202",
      parent_ref: "Sample#201",
      parent_workspace_ref: "Sample#201-parent",
      scopes: [:ticket_workspace],
      dry_run: false
    )

    expect(cleaned_paths).to contain_exactly(intended_child.to_s)
    expect(intended_child).not_to exist
    expect(other_child).to exist
  end

  it "does not resolve parentless cleanup through ambiguous child glob fallback" do
    child = Pathname(tmpdir).join("workspaces", "Sample-999", "children", "Sample-202", "ticket_workspace")
    FileUtils.mkdir_p(child)

    provisioner = described_class.new(base_dir: tmpdir, repo_sources: {})
    cleaned_paths = provisioner.cleanup_task(
      task_ref: "Sample#202",
      scopes: [:ticket_workspace],
      dry_run: false
    )

    expect(cleaned_paths).to be_empty
    expect(child).to exist
  end

  it "reports cleanup candidates during dry-run without deleting paths" do
    task_root = Pathname(tmpdir).join("workspaces", "A3-v2-3025")
    runtime_path = task_root.join("runtime_workspace")
    quarantine_path = Pathname(tmpdir).join("quarantine", "A3-v2-3025")
    FileUtils.mkdir_p(runtime_path)
    FileUtils.mkdir_p(quarantine_path)

    provisioner = described_class.new(base_dir: tmpdir, repo_sources: {})
    cleaned_paths = provisioner.cleanup_task(
      task_ref: "A3-v2#3025",
      scopes: %i[runtime_workspace quarantine],
      dry_run: true
    )

    expect(cleaned_paths).to contain_exactly(runtime_path.to_s, quarantine_path.to_s)
    expect(runtime_path).to exist
    expect(quarantine_path).to exist
  end

  it "bootstraps a missing branch-head ref for runtime workspace git materialization" do
    repo_root = Pathname(File.join(tmpdir, "repo-beta"))
    create_git_repo_source(tmpdir, name: "repo-beta")
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :single,
      edit_scope: [:repo_beta]
    )
    workspace_plan = A3::Domain::WorkspacePlan.new(
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a2o/work/A3-v2-3025",
        task_ref: task.ref
      ),
      slot_requirements: [
        A3::Domain::SlotRequirement.new(repo_slot: :repo_beta, sync_class: :eager)
      ]
    )
    provisioner = described_class.new(base_dir: tmpdir, repo_sources: { repo_beta: repo_root.to_s })

    workspace = provisioner.call(
      task: task,
      workspace_plan: workspace_plan,
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :task,
        snapshot_version: "refs/heads/a2o/work/A3-v2-3025"
      ),
      bootstrap_marker: nil
    )

    branch_ref = `git -C #{repo_root} rev-parse refs/heads/a2o/work/A3-v2-3025`.strip
    head_ref = `git -C #{repo_root} rev-parse HEAD`.strip
    expect(branch_ref).to eq(head_ref)
    expect(workspace.slot_paths.fetch(:repo_beta)).to exist
  end

  it "re-materializes ticket workspaces from a fresh branch-head baseline on each call" do
    repo_root = Pathname(File.join(tmpdir, "repo-beta"))
    create_git_repo_source(tmpdir, name: "repo-beta")
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :single,
      edit_scope: [:repo_beta]
    )
    workspace_plan = A3::Domain::WorkspacePlan.new(
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a2o/work/A3-v2-3025",
        task_ref: task.ref
      ),
      slot_requirements: [
        A3::Domain::SlotRequirement.new(repo_slot: :repo_beta, sync_class: :eager)
      ]
    )
    provisioner = described_class.new(base_dir: tmpdir, repo_sources: { repo_beta: repo_root.to_s })

    first_workspace = provisioner.call(
      task: task,
      workspace_plan: workspace_plan,
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :task,
        snapshot_version: "refs/heads/a2o/work/A3-v2-3025"
      ),
      bootstrap_marker: nil
    )
    first_slot = first_workspace.slot_paths.fetch(:repo_beta)
    first_slot.join("LOCAL_ONLY.txt").write("stale\n")
    system("git", "-C", first_slot.to_s, "add", "LOCAL_ONLY.txt", exception: true)
    system("git", "-C", first_slot.to_s, "commit", "-m", "stale task branch state", exception: true)

    File.write(repo_root.join("FRESH.md"), "fresh\n")
    system("git", "-C", repo_root.to_s, "add", "FRESH.md", exception: true)
    system("git", "-C", repo_root.to_s, "commit", "-m", "advance base", exception: true)

    second_workspace = provisioner.call(
      task: task,
      workspace_plan: workspace_plan,
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :task,
        snapshot_version: "refs/heads/a2o/work/A3-v2-3025"
      ),
      bootstrap_marker: nil
    )
    second_slot = second_workspace.slot_paths.fetch(:repo_beta)
    branch_ref = `git -C #{repo_root} rev-parse refs/heads/a2o/work/A3-v2-3025`.strip
    head_ref = `git -C #{repo_root} rev-parse HEAD`.strip

    expect(branch_ref).to eq(head_ref)
    expect(`git -C #{second_slot} rev-parse HEAD`.strip).to eq(head_ref)
    expect(second_slot.join("LOCAL_ONLY.txt")).not_to exist
    expect(second_slot.join("FRESH.md")).to exist
  end

  it "places child ticket workspaces under the parent workspace and bootstraps parent integration slots as worktrees" do
    repo_root = Pathname(File.join(tmpdir, "repo-alpha"))
    create_git_repo_source(tmpdir, name: "repo-alpha")
    task = A3::Domain::Task.new(
      ref: "Sample#135",
      kind: :child,
      edit_scope: [:repo_alpha],
      parent_ref: "Sample#134"
    )
    workspace_plan = A3::Domain::WorkspacePlan.new(
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a2o/work/Sample-135",
        task_ref: task.ref
      ),
      slot_requirements: [
        A3::Domain::SlotRequirement.new(repo_slot: :repo_alpha, sync_class: :eager)
      ]
    )
    provisioner = described_class.new(base_dir: tmpdir, repo_sources: { repo_alpha: repo_root.to_s })

    workspace = provisioner.call(
      task: task,
      workspace_plan: workspace_plan,
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "Sample#134",
        owner_scope: :task,
        snapshot_version: "refs/heads/a2o/work/Sample-135"
      ),
      bootstrap_marker: nil
    )

    parent_root = Pathname(tmpdir).join("workspaces", "Sample-134-parent", "runtime_workspace")
    parent_slot = parent_root.join("repo-alpha")
    expect(workspace.root_path).to eq(Pathname(tmpdir).join("workspaces", "Sample-134-parent", "children", "Sample-135", "ticket_workspace"))
    expect(workspace.slot_paths.fetch(:repo_alpha)).to eq(workspace.root_path.join("repo-alpha"))
    expect(parent_slot).to exist
    expect(`git -C #{repo_root} worktree list --porcelain`).to include(parent_slot.to_s)
    expect(`git -C #{repo_root} rev-parse refs/heads/a2o/parent/Sample-134`.strip).to eq(`git -C #{parent_slot} rev-parse HEAD`.strip)
  end
end
