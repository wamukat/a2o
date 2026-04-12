# frozen_string_literal: true

require "spec_helper"

RSpec.describe A3::Infra::AgentWorkspaceRequestBuilder do
  let(:source_descriptor) { A3::Domain::SourceDescriptor.implementation(task_ref: "Portal#42", ref: "refs/heads/a3/work/Portal-42") }
  let(:task) do
    A3::Domain::Task.new(
      ref: "Portal#42",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_beta]
    )
  end
  let(:workspace) do
    A3::Domain::PreparedWorkspace.new(
      workspace_kind: :ticket_workspace,
      root_path: "/tmp/a3-local-workspace",
      source_descriptor: source_descriptor,
      slot_paths: {}
    )
  end

  it "builds all configured slots and marks edit scope with read-write access" do
    request = support_ref_builder.call(workspace: workspace, task: task, run: run(:implementation))

    expect(request.workspace_kind).to eq(:ticket_workspace)
    expect(request.workspace_id).to eq("Portal-42-implementation-run-implementation")
    expect(request.publish_policy).to eq(
      "mode" => "commit_declared_changes_on_success",
      "commit_message" => "A3 implementation update for Portal#42"
    )
    expect(request.slots.keys).to eq(%w[repo_alpha repo_beta])
    expect(request.slots.fetch("repo_alpha")).to include(
      "ref" => "refs/heads/a3/work/Portal-42",
      "checkout" => "worktree_branch",
      "access" => "read_write",
      "sync_class" => "eager",
      "ownership" => "edit_target",
      "required" => true
    )
    expect(request.slots.fetch("repo_beta")).to include(
      "checkout" => "worktree_branch",
      "access" => "read_only",
      "sync_class" => "lazy_but_guaranteed",
      "ownership" => "support",
      "required" => true
    )
    expect(request.slots.fetch("repo_alpha").fetch("source")).to eq(
      "kind" => "local_git",
      "alias" => "portal-alpha"
    )
  end

  it "uses parent-owned workspace ids for child tasks with a parent ref" do
    parented_task = A3::Domain::Task.new(
      ref: "Portal#135",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      parent_ref: "Portal#134"
    )
    parented_run = A3::Domain::Run.new(
      ref: "run-implementation",
      task_ref: parented_task.ref,
      phase: :implementation,
      workspace_kind: workspace.workspace_kind,
      source_descriptor: A3::Domain::SourceDescriptor.implementation(
        task_ref: parented_task.ref,
        ref: "refs/heads/a3/work/Portal-135"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: parented_task.edit_scope,
        verification_scope: parented_task.verification_scope,
        ownership_scope: :child
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: parented_task.parent_ref,
        owner_scope: :task,
        snapshot_version: "refs/heads/a3/work/Portal-135"
      )
    )

    request = support_ref_builder.call(workspace: workspace, task: parented_task, run: parented_run)

    expect(request.workspace_id).to eq("Portal-134-children-Portal-135-implementation-run-implementation")
  end

  it "uses the support ref for non-edit slots" do
    builder = described_class.new(
      source_aliases: {
        repo_alpha: "portal-alpha",
        repo_beta: "portal-beta"
      },
      support_ref: "refs/heads/feature/prototype"
    )

    request = builder.call(workspace: workspace, task: task, run: run(:implementation))

    expect(request.slots.fetch("repo_alpha")).to include(
      "ref" => "refs/heads/a3/work/Portal-42",
      "ownership" => "edit_target"
    )
    expect(request.slots.fetch("repo_beta")).to include(
      "ref" => "refs/heads/feature/prototype",
      "ownership" => "support",
      "access" => "read_only"
    )
  end

  it "keeps support slots present for verification even when the scope is narrow" do
    request = described_class.new(
      source_aliases: {
        repo_alpha: "portal-alpha",
        repo_beta: "portal-beta"
      },
      support_ref: "refs/heads/feature/prototype"
    ).call(workspace: workspace, task: task, run: run(:verification))

    expect(request.publish_policy).to be_nil
    expect(request.slots.keys).to eq(%w[repo_alpha repo_beta])
    expect(request.slots.fetch("repo_alpha")).to include(
      "access" => "read_only",
      "sync_class" => "eager"
    )
    expect(request.slots.fetch("repo_beta")).to include(
      "ref" => "refs/heads/feature/prototype",
      "access" => "read_only",
      "sync_class" => "lazy_but_guaranteed"
    )
  end

  it "fails closed when support slots are requested without a support ref" do
    expect do
      builder.call(workspace: workspace, task: task, run: run(:implementation))
    end.to raise_error(A3::Domain::ConfigurationError, /support slot repo_beta requires --agent-support-ref/)
  end

  it "builds review slots from edit and verification scopes with edit slots writable" do
    request = described_class.new(
      source_aliases: {
        repo_alpha: "portal-alpha",
        repo_beta: "portal-beta"
      },
      support_ref: "refs/heads/feature/prototype"
    ).call(workspace: workspace, task: task, run: run(:review))

    expect(request.slots.keys).to eq(%w[repo_alpha repo_beta])
    expect(request.slots.transform_values { |slot| slot.fetch("access") }).to eq(
      "repo_alpha" => "read_write",
      "repo_beta" => "read_only"
    )
  end

  it "uses the configured source alias keys as the required slot universe" do
    builder = described_class.new(source_aliases: { repo_alpha: "portal-alpha" })

    request = builder.call(workspace: workspace, task: task, run: run(:verification))

    expect(request.slots.keys).to eq(["repo_alpha"])
  end

  it "fails for unsupported merge phase" do
    expect do
      builder.call(workspace: workspace, task: task, run: run(:merge))
    end.to raise_error(A3::Domain::ConfigurationError, /not supported for phase merge/)
  end

  it "fails fast for unsupported workspace policies" do
    expect do
      described_class.new(source_aliases: { repo_alpha: "portal-alpha" }, cleanup_policy: :delete_everything)
    end.to raise_error(A3::Domain::ConfigurationError, /unsupported agent workspace cleanup_policy/)
  end

  def builder
    described_class.new(
      source_aliases: {
        repo_alpha: "portal-alpha",
        repo_beta: "portal-beta"
      }
    )
  end

  def support_ref_builder
    described_class.new(
      source_aliases: {
        repo_alpha: "portal-alpha",
        repo_beta: "portal-beta"
      },
      support_ref: "refs/heads/feature/prototype"
    )
  end

  def run(phase)
    A3::Domain::Run.new(
      ref: "run-#{phase}",
      task_ref: task.ref,
      phase: phase,
      workspace_kind: workspace.workspace_kind,
      source_descriptor: source_descriptor,
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: task.edit_scope,
        verification_scope: task.verification_scope,
        ownership_scope: :child
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :child,
        snapshot_version: "head-1"
      )
    )
  end
end
