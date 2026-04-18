# frozen_string_literal: true

RSpec.describe A3::Application::PlanRerun do
  subject(:use_case) { described_class.new }

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
      snapshot_version: "snap-1"
    )
  end

  let(:source_descriptor) do
    A3::Domain::SourceDescriptor.new(
      workspace_kind: :runtime_workspace,
      source_type: :detached_commit,
      ref: "head456",
      task_ref: "A3-v2#3025"
    )
  end

  it "returns same_phase_retry when evidence points to the same intent" do
    run = A3::Domain::Run.new(
      ref: "run-1",
      task_ref: "A3-v2#3025",
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor,
      scope_snapshot: scope_snapshot,
      review_target: review_target,
      artifact_owner: artifact_owner
    )

    result = use_case.call(
      run: run,
      current_source_descriptor: source_descriptor,
      current_review_target: review_target,
      current_scope_snapshot: scope_snapshot,
      current_artifact_owner: artifact_owner
    )

    expect(result.decision).to eq(:same_phase_retry)
  end

  it "returns requires_new_implementation when review target changed" do
    run = A3::Domain::Run.new(
      ref: "run-2",
      task_ref: "A3-v2#3025",
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor,
      scope_snapshot: scope_snapshot,
      review_target: review_target,
      artifact_owner: artifact_owner
    )

    result = use_case.call(
      run: run,
      current_source_descriptor: source_descriptor,
      current_review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head999",
        task_ref: "A3-v2#3025",
        phase_ref: :review
      ),
      current_scope_snapshot: scope_snapshot,
      current_artifact_owner: artifact_owner
    )

    expect(result.decision).to eq(:requires_new_implementation)
  end

  it "returns requires_operator_action when source descriptor changed but review target did not" do
    run = A3::Domain::Run.new(
      ref: "run-3",
      task_ref: "A3-v2#3025",
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor,
      scope_snapshot: scope_snapshot,
      review_target: review_target,
      artifact_owner: artifact_owner
    )

    result = use_case.call(
      run: run,
      current_source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a2o/work/3025",
        task_ref: "A3-v2#3025"
      ),
      current_review_target: review_target,
      current_scope_snapshot: scope_snapshot,
      current_artifact_owner: artifact_owner
    )

    expect(result.decision).to eq(:requires_operator_action)
  end

  it "returns terminal_noop for terminal done runs" do
    run = A3::Domain::Run.new(
      ref: "run-4",
      task_ref: "A3-v2#3025",
      phase: :merge,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor,
      scope_snapshot: scope_snapshot,
      review_target: review_target,
      artifact_owner: artifact_owner,
      terminal_outcome: :completed
    )

    result = use_case.call(
      run: run,
      current_source_descriptor: source_descriptor,
      current_review_target: review_target,
      current_scope_snapshot: scope_snapshot,
      current_artifact_owner: artifact_owner
    )

    expect(result.decision).to eq(:terminal_noop)
  end

  it "returns requires_operator_action for terminal blocked runs" do
    run = A3::Domain::Run.new(
      ref: "run-4b",
      task_ref: "A3-v2#3025",
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor,
      scope_snapshot: scope_snapshot,
      review_target: review_target,
      artifact_owner: artifact_owner,
      terminal_outcome: :blocked
    )

    result = use_case.call(
      run: run,
      current_source_descriptor: source_descriptor,
      current_review_target: review_target,
      current_scope_snapshot: scope_snapshot,
      current_artifact_owner: artifact_owner
    )

    expect(result.decision).to eq(:requires_operator_action)
  end

  it "returns same_phase_retry for terminal retryable runs with the same intent" do
    run = A3::Domain::Run.new(
      ref: "run-4c",
      task_ref: "A3-v2#3025",
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor,
      scope_snapshot: scope_snapshot,
      review_target: review_target,
      artifact_owner: artifact_owner,
      terminal_outcome: :retryable
    )

    result = use_case.call(
      run: run,
      current_source_descriptor: source_descriptor,
      current_review_target: review_target,
      current_scope_snapshot: scope_snapshot,
      current_artifact_owner: artifact_owner
    )

    expect(result.decision).to eq(:same_phase_retry)
  end

  it "returns requires_operator_action when scope snapshot changed" do
    run = A3::Domain::Run.new(
      ref: "run-5",
      task_ref: "A3-v2#3025",
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor,
      scope_snapshot: scope_snapshot,
      review_target: review_target,
      artifact_owner: artifact_owner
    )

    changed_scope = A3::Domain::ScopeSnapshot.new(
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha, :repo_beta],
      ownership_scope: :task
    )

    result = use_case.call(
      run: run,
      current_source_descriptor: source_descriptor,
      current_review_target: review_target,
      current_scope_snapshot: changed_scope,
      current_artifact_owner: artifact_owner
    )

    expect(result.decision).to eq(:requires_operator_action)
  end

  it "returns requires_operator_action when artifact owner changed" do
    run = A3::Domain::Run.new(
      ref: "run-6",
      task_ref: "A3-v2#3025",
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor,
      scope_snapshot: scope_snapshot,
      review_target: review_target,
      artifact_owner: artifact_owner
    )

    result = use_case.call(
      run: run,
      current_source_descriptor: source_descriptor,
      current_review_target: review_target,
      current_scope_snapshot: scope_snapshot,
      current_artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3025",
        owner_scope: :task,
        snapshot_version: "snap-2"
      )
    )

    expect(result.decision).to eq(:requires_operator_action)
  end
end
