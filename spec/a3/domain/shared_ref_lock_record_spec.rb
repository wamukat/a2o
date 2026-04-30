# frozen_string_literal: true

RSpec.describe A3::Domain::SharedRefLockRecord do
  it "persists shared-ref lock records and exposes the lock key" do
    lock = described_class.new(
      lock_ref: "lock-1",
      project_key: "a2o",
      operation: :publish,
      repo_slot: :repo_beta,
      target_ref: "refs/heads/a2o/work/Sample-42",
      run_ref: "run-1",
      claimed_at: "2026-04-30T00:00:00Z"
    )

    restored = described_class.from_persisted_form(lock.persisted_form)

    expect(restored.shared_ref_key).to eq("shared-ref:repo_beta:refs/heads/a2o/work/Sample-42")
    expect(restored.persisted_form).to eq(lock.persisted_form)
  end
end
