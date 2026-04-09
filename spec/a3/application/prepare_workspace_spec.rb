# frozen_string_literal: true

require "pathname"

RSpec.describe A3::Application::PrepareWorkspace do
  let(:workspace_plan) do
    A3::Domain::WorkspacePlan.new(
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "abc123",
        task_ref: "A3-v2#3025"
      ),
      slot_requirements: [
        A3::Domain::SlotRequirement.new(repo_slot: :repo_alpha, sync_class: :eager),
        A3::Domain::SlotRequirement.new(repo_slot: :repo_beta, sync_class: :lazy_but_guaranteed)
      ]
    )
  end

  let(:prepared_workspace) do
    A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: Pathname("/tmp/a3-v2/runtime"),
      source_descriptor: workspace_plan.source_descriptor,
      slot_paths: {
        repo_alpha: Pathname("/tmp/a3-v2/runtime/repo-alpha"),
        repo_beta: Pathname("/tmp/a3-v2/runtime/repo-beta")
      }
    )
  end
  let(:artifact_owner) do
    A3::Domain::ArtifactOwner.new(
      owner_ref: "A3-v2#3022",
      owner_scope: :task,
      snapshot_version: "abc123"
    )
  end

  let(:workspace_plan_builder) { instance_double(A3::Application::BuildWorkspacePlan) }
  let(:provisioner) { instance_double("WorkspaceProvisioner") }

  subject(:use_case) do
    described_class.new(
      workspace_plan_builder: workspace_plan_builder,
      provisioner: provisioner
    )
  end

  it "builds a workspace plan and provisions slot paths from it" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: %i[repo_alpha repo_beta]
    )
    scope_snapshot = A3::Domain::ScopeSnapshot.new(
      edit_scope: [:repo_alpha],
      verification_scope: %i[repo_alpha repo_beta],
      ownership_scope: :task
    )
    source_descriptor = workspace_plan.source_descriptor

    expect(workspace_plan_builder).to receive(:call).with(
      phase: :review,
      source_descriptor: source_descriptor,
      scope_snapshot: scope_snapshot
    ).and_return(workspace_plan)
    expect(provisioner).to receive(:call).with(
      task: task,
      workspace_plan: workspace_plan,
      artifact_owner: artifact_owner,
      bootstrap_marker: "workspace-hook:v1"
    ).and_return(prepared_workspace)

    result = use_case.call(
      task: task,
      phase: :review,
      source_descriptor: source_descriptor,
      scope_snapshot: scope_snapshot,
      artifact_owner: artifact_owner,
      bootstrap_marker: "workspace-hook:v1"
    )

    expect(result.workspace).to eq(prepared_workspace)
  end
end
