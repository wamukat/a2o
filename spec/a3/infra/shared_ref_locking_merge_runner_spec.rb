# frozen_string_literal: true

RSpec.describe A3::Infra::SharedRefLockingMergeRunner do
  let(:inner) { instance_double("MergeRunner", agent_owned?: true) }
  let(:lock_repository) { A3::Infra::InMemorySharedRefLockRepository.new(lock_ref_generator: -> { "lock-1" }) }
  let(:lock_guard) { A3::Application::SharedRefLockGuard.new(lock_repository: lock_repository, clock: -> { "2026-04-30T00:00:00Z" }) }
  let(:merge_plan) do
    A3::Domain::MergePlan.new(
      project_key: "a2o",
      task_ref: "A2O#1",
      run_ref: "run-1",
      merge_source: A3::Domain::MergeSource.new(source_ref: "refs/heads/a2o/work/A2O-1"),
      integration_target: A3::Domain::IntegrationTarget.new(target_ref: "refs/heads/main"),
      merge_policy: :ff_only,
      merge_slots: [:repo_beta]
    )
  end

  it "holds a shared-ref lock while running the inner merge runner" do
    allow(inner).to receive(:run) do
      expect(lock_repository.active_locks.map(&:shared_ref_key)).to eq(["shared-ref:repo_beta:refs/heads/main"])
      A3::Application::ExecutionResult.new(success: true, summary: "merged")
    end

    result = described_class.new(inner: inner, lock_guard: lock_guard).run(merge_plan, workspace: Object.new)

    expect(result.success).to be(true)
    expect(lock_repository.active_locks).to be_empty
  end

  it "returns waiting_for_shared_ref_lock when another run holds the target ref" do
    allow(inner).to receive(:run)
    lock_repository.acquire(
      operation: :publish,
      repo_slot: :repo_beta,
      target_ref: "refs/heads/main",
      run_ref: "run-other",
      claimed_at: "2026-04-30T00:00:00Z",
      project_key: "a2o"
    )

    result = described_class.new(inner: inner, lock_guard: lock_guard).run(merge_plan, workspace: Object.new)

    expect(result.success).to be(false)
    expect(result.observed_state).to eq("waiting_for_shared_ref_lock")
    expect(inner).not_to have_received(:run)
  end
end
