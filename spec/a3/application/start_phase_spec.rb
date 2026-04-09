# frozen_string_literal: true

RSpec.describe A3::Application::StartPhase do
  subject(:use_case) { described_class.new }

  let(:run_id_generator) { instance_double("Proc") }

  let(:source_descriptor) do
    A3::Domain::SourceDescriptor.new(
      workspace_kind: :ticket_workspace,
      source_type: :branch_head,
      ref: "refs/heads/a3/work/A3-v2-3025",
      task_ref: "A3-v2#3025"
    )
  end

  let(:scope_snapshot) do
    A3::Domain::ScopeSnapshot.new(
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      ownership_scope: :task
    )
  end

  let(:review_target) do
    A3::Domain::ReviewTarget.new(
      base_commit: "base123",
      head_commit: "head456",
      task_ref: "A3-v2#3025",
      phase_ref: :review
    )
  end

  let(:artifact_owner) do
    A3::Domain::ArtifactOwner.new(
      owner_ref: "A3-v2#3025",
      owner_scope: :task,
      snapshot_version: "head456"
    )
  end

  before do
    allow(run_id_generator).to receive(:call).and_return("run-1")
  end

  it "starts implementation on the ticket workspace" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha]
    )

    result = described_class.new(run_id_generator: run_id_generator).call(
      task: task,
      phase: :implementation,
      source_descriptor: source_descriptor,
      scope_snapshot: scope_snapshot,
      review_target: review_target,
      artifact_owner: artifact_owner
    )

    expect(result.run.phase).to eq(:implementation)
    expect(result.run.ref).to eq("run-1")
    expect(result.run.workspace_kind).to eq(:ticket_workspace)
    expect(result.run.phase_records.size).to eq(1)
    expect(result.run.phase_records.first.phase).to eq(:implementation)
  end

  it "starts review on the runtime workspace" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha]
    )
    runtime_source_descriptor = A3::Domain::SourceDescriptor.new(
      workspace_kind: :runtime_workspace,
      source_type: :branch_head,
      ref: "refs/heads/a3/work/A3-v2-3025",
      task_ref: task.ref
    )

    result = described_class.new(run_id_generator: run_id_generator).call(
      task: task,
      phase: :review,
      source_descriptor: runtime_source_descriptor,
      scope_snapshot: scope_snapshot,
      review_target: review_target,
      artifact_owner: artifact_owner
    )

    expect(result.run.phase).to eq(:review)
    expect(result.run.workspace_kind).to eq(:runtime_workspace)
    expect(result.run.evidence.review_target).to eq(review_target)
  end

  it "rejects a source descriptor that does not match the canonical phase input" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha]
    )
    mismatched_source_descriptor = A3::Domain::SourceDescriptor.new(
      workspace_kind: :runtime_workspace,
      source_type: :detached_commit,
      ref: "refs/heads/a3/work/A3-v2-3025",
      task_ref: task.ref
    )

    expect do
      described_class.new(run_id_generator: run_id_generator).call(
        task: task,
        phase: :review,
        source_descriptor: mismatched_source_descriptor,
        scope_snapshot: scope_snapshot,
        review_target: review_target,
        artifact_owner: artifact_owner
      )
    end.to raise_error(
      A3::Domain::ConfigurationError,
      /phase review requires runtime_workspace\/branch_head source descriptor/
    )
  end

  it "rejects unsupported phases" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3022",
      kind: :parent,
      edit_scope: [:repo_beta, :repo_alpha]
    )

    expect do
      described_class.new(run_id_generator: run_id_generator).call(
        task: task,
        phase: :implementation,
        source_descriptor: source_descriptor,
        scope_snapshot: scope_snapshot,
        review_target: review_target,
        artifact_owner: artifact_owner
      )
    end.to raise_error(A3::Domain::InvalidPhaseError)
  end
end
