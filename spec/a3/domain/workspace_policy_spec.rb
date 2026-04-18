# frozen_string_literal: true

RSpec.describe A3::Domain::WorkspacePolicy do
  subject(:policy) { described_class.new }

  let(:implementation_source_descriptor) do
    A3::Domain::SourceDescriptor.new(
      workspace_kind: :ticket_workspace,
      source_type: :branch_head,
      ref: "refs/heads/a2o/work/3025",
      task_ref: "A3-v2#3025"
    )
  end

  let(:scope_snapshot) do
    A3::Domain::ScopeSnapshot.new(
      edit_scope: [:repo_alpha],
      verification_scope: %i[repo_alpha repo_beta],
      ownership_scope: :task
    )
  end

  it "builds a workspace plan with slot requirements from the scope snapshot" do
    plan = policy.build_plan(
      phase: :implementation,
      source_descriptor: implementation_source_descriptor,
      scope_snapshot: scope_snapshot
    )

    expect(plan.workspace_kind).to eq(:ticket_workspace)
    expect(plan.slot_requirements).to contain_exactly(
      have_attributes(repo_slot: :repo_alpha, sync_class: :eager),
      have_attributes(repo_slot: :repo_beta, sync_class: :lazy_but_guaranteed)
    )
  end

  it "uses the configured repo slot universe instead of filtering by scope" do
    policy = described_class.new(repo_slots: %i[repo_alpha repo_beta])
    ui_only_scope = A3::Domain::ScopeSnapshot.new(
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      ownership_scope: :task
    )

    plan = policy.build_plan(
      phase: :implementation,
      source_descriptor: implementation_source_descriptor,
      scope_snapshot: ui_only_scope
    )

    expect(plan.slot_requirements).to contain_exactly(
      have_attributes(repo_slot: :repo_alpha, sync_class: :lazy_but_guaranteed),
      have_attributes(repo_slot: :repo_beta, sync_class: :eager)
    )
  end

  it "rejects a source descriptor whose workspace kind does not match the phase policy" do
    runtime_source_descriptor = implementation_source_descriptor.with_workspace_kind(:runtime_workspace)

    expect do
      policy.build_plan(
        phase: :implementation,
        source_descriptor: runtime_source_descriptor,
        scope_snapshot: scope_snapshot
      )
    end.to raise_error(A3::Domain::ConfigurationError, /phase implementation requires ticket_workspace source descriptor/)
  end
end
