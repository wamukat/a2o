# frozen_string_literal: true

RSpec.describe A3::Domain::RerunPolicy do
  subject(:policy) { described_class.new }

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

  def build_run(terminal_outcome: nil)
    A3::Domain::Run.new(
      ref: "run-1",
      task_ref: "A3-v2#3025",
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor,
      scope_snapshot: scope_snapshot,
      review_target: review_target,
      artifact_owner: artifact_owner,
      terminal_outcome: terminal_outcome
    )
  end

  it "returns same_phase_retry for non-terminal runs with the same intent" do
    decision = policy.decide(
      run: build_run,
      current_source_descriptor: source_descriptor,
      current_review_target: review_target,
      current_scope_snapshot: scope_snapshot,
      current_artifact_owner: artifact_owner
    )

    expect(decision).to eq(:same_phase_retry)
  end

  it "returns requires_new_implementation when review target changed" do
    decision = policy.decide(
      run: build_run,
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

    expect(decision).to eq(:requires_new_implementation)
  end

  it "returns requires_operator_action for terminal blocked runs" do
    decision = policy.decide(
      run: build_run(terminal_outcome: :blocked),
      current_source_descriptor: source_descriptor,
      current_review_target: review_target,
      current_scope_snapshot: scope_snapshot,
      current_artifact_owner: artifact_owner
    )

    expect(decision).to eq(:requires_operator_action)
  end
end
