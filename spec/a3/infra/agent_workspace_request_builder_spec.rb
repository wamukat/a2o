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

  it "builds implementation slots from edit scope with read-write access" do
    request = builder.call(workspace: workspace, task: task, run: run(:implementation))

    expect(request.workspace_kind).to eq(:ticket_workspace)
    expect(request.workspace_id).to eq("Portal-42-implementation-run-implementation")
    expect(request.slots.keys).to eq(["repo_alpha"])
    expect(request.slots.fetch("repo_alpha")).to include(
      "ref" => "refs/heads/a3/work/Portal-42",
      "checkout" => "worktree_detached",
      "access" => "read_write",
      "required" => true
    )
    expect(request.slots.fetch("repo_alpha").fetch("source")).to eq(
      "kind" => "local_git",
      "alias" => "portal-alpha"
    )
  end

  it "builds verification slots from verification scope with read-only access" do
    request = builder.call(workspace: workspace, task: task, run: run(:verification))

    expect(request.slots.keys).to eq(["repo_beta"])
    expect(request.slots.fetch("repo_beta")).to include(
      "ref" => "refs/heads/a3/work/Portal-42",
      "access" => "read_only"
    )
  end

  it "builds review slots from edit and verification scopes with edit slots writable" do
    request = builder.call(workspace: workspace, task: task, run: run(:review))

    expect(request.slots.keys).to eq(%w[repo_alpha repo_beta])
    expect(request.slots.transform_values { |slot| slot.fetch("access") }).to eq(
      "repo_alpha" => "read_write",
      "repo_beta" => "read_only"
    )
  end

  it "fails when a required slot alias is missing" do
    builder = described_class.new(source_aliases: { repo_alpha: "portal-alpha" })

    expect do
      builder.call(workspace: workspace, task: task, run: run(:verification))
    end.to raise_error(A3::Domain::ConfigurationError, /missing agent source alias for repo_beta/)
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
