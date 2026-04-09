# frozen_string_literal: true

RSpec.describe A3::Application::PlanPersistedRerun do
  subject(:use_case) do
    described_class.new(
      task_repository: task_repository,
      run_repository: run_repository,
      plan_rerun: A3::Application::PlanRerun.new,
      build_scope_snapshot: A3::Application::BuildScopeSnapshot.new,
      build_artifact_owner: A3::Application::BuildArtifactOwner.new
    )
  end

  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:run_repository) { A3::Infra::InMemoryRunRepository.new }

  let(:task) do
    A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha, :repo_beta],
      parent_ref: "A3-v2#3022"
    )
  end

  let(:run) do
    A3::Domain::Run.new(
      ref: "run-1",
      task_ref: task.ref,
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "head456",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha, :repo_beta],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :task,
        snapshot_version: "head456"
      )
    )
  end

  before do
    task_repository.save(task)
    run_repository.save(run)
  end

  it "returns same_phase_retry when current intent matches persisted evidence" do
    result = use_case.call(
      task_ref: task.ref,
      run_ref: run.ref,
      current_source_type: :detached_commit,
      current_source_ref: "head456",
      current_review_base: "base123",
      current_review_head: "head456",
      snapshot_version: "head456"
    )

    expect(result.decision).to eq(:same_phase_retry)
    expect(result.task).to eq(task)
    expect(result.run).to eq(run)
  end

  it "returns requires_new_implementation when the review head changed" do
    result = use_case.call(
      task_ref: task.ref,
      run_ref: run.ref,
      current_source_type: :detached_commit,
      current_source_ref: "head999",
      current_review_base: "base123",
      current_review_head: "head999",
      snapshot_version: "head999"
    )

    expect(result.decision).to eq(:requires_new_implementation)
  end
end
