# frozen_string_literal: true

RSpec.describe A3::Application::BuildWorkspacePlan do
  subject(:use_case) { described_class.new }

  let(:implementation_source_descriptor) do
    A3::Domain::SourceDescriptor.new(
      workspace_kind: :ticket_workspace,
      source_type: :branch_head,
      ref: "refs/heads/a3/work/3025",
      task_ref: "A3-v2#3025"
    )
  end

  let(:review_source_descriptor) do
    A3::Domain::SourceDescriptor.new(
      workspace_kind: :runtime_workspace,
      source_type: :detached_commit,
      ref: "head456",
      task_ref: "A3-v2#3025"
    )
  end

  it "uses eager sync for implementation edit scope" do
    scope_snapshot = A3::Domain::ScopeSnapshot.new(
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha, :repo_beta],
      ownership_scope: :task
    )

    plan = use_case.call(
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

  it "adds verification-only repos as lazy_but_guaranteed during review" do
    scope_snapshot = A3::Domain::ScopeSnapshot.new(
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha, :repo_beta],
      ownership_scope: :task
    )

    plan = use_case.call(
      phase: :review,
      source_descriptor: review_source_descriptor,
      scope_snapshot: scope_snapshot
    )

    expect(plan.workspace_kind).to eq(:runtime_workspace)
    expect(plan.slot_requirements).to contain_exactly(
      have_attributes(repo_slot: :repo_alpha, sync_class: :eager),
      have_attributes(repo_slot: :repo_beta, sync_class: :lazy_but_guaranteed)
    )
  end

  it "keeps merge on the runtime workspace" do
    scope_snapshot = A3::Domain::ScopeSnapshot.new(
      edit_scope: [:repo_beta, :repo_alpha],
      verification_scope: [:repo_beta, :repo_alpha],
      ownership_scope: :parent
    )

    plan = use_case.call(
      phase: :merge,
      source_descriptor: review_source_descriptor,
      scope_snapshot: scope_snapshot
    )

    expect(plan.workspace_kind).to eq(:runtime_workspace)
    expect(plan.source_descriptor.workspace_kind).to eq(:runtime_workspace)
  end

  it "rejects implementation when the source descriptor points at a runtime workspace" do
    scope_snapshot = A3::Domain::ScopeSnapshot.new(
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      ownership_scope: :task
    )

    expect do
      use_case.call(
        phase: :implementation,
        source_descriptor: review_source_descriptor,
        scope_snapshot: scope_snapshot
      )
    end.to raise_error(
      A3::Domain::ConfigurationError,
      /phase implementation requires ticket_workspace source descriptor/
    )
  end

  it "rejects review when the source descriptor points at a ticket workspace" do
    scope_snapshot = A3::Domain::ScopeSnapshot.new(
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha, :repo_beta],
      ownership_scope: :task
    )

    expect do
      use_case.call(
        phase: :review,
        source_descriptor: implementation_source_descriptor,
        scope_snapshot: scope_snapshot
      )
    end.to raise_error(
      A3::Domain::ConfigurationError,
      /phase review requires runtime_workspace source descriptor/
    )
  end
end
