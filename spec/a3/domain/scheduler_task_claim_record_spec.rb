# frozen_string_literal: true

RSpec.describe A3::Domain::SchedulerTaskClaimRecord do
  it "persists and restores claimed scheduler task claims" do
    claim = described_class.new(
      claim_ref: "claim-1",
      project_key: "portal",
      task_ref: "Portal#1",
      phase: :implementation,
      parent_group_key: "single:Portal#1",
      state: :claimed,
      claimed_by: "scheduler-1",
      claimed_at: "2026-04-30T00:00:00Z"
    )

    restored = described_class.from_persisted_form(claim.persisted_form)

    expect(restored).to eq(claim)
    expect(restored.active?).to be(true)
  end

  it "links runs, heartbeats, releases, and marks stale" do
    claim = described_class.new(
      claim_ref: "claim-1",
      task_ref: "A2O#1",
      phase: :review,
      parent_group_key: "parent-group:A2O#1",
      state: :claimed,
      claimed_by: "scheduler-1",
      claimed_at: "2026-04-30T00:00:00Z"
    )

    linked = claim.link_run(run_ref: "run-1")
    heartbeated = linked.heartbeat(heartbeat_at: "2026-04-30T00:00:10Z")
    released = heartbeated.release
    stale = linked.mark_stale(reason: "scheduler process exited")

    expect(linked.run_ref).to eq("run-1")
    expect(heartbeated.heartbeat_at).to eq("2026-04-30T00:00:10Z")
    expect(released.state).to eq(:released)
    expect(stale.state).to eq(:stale)
    expect(stale.stale_reason).to eq("scheduler process exited")
  end

  it "rejects claimed records without claim ownership" do
    expect do
      described_class.new(
        claim_ref: "claim-1",
        task_ref: "A2O#1",
        phase: :implementation,
        parent_group_key: "single:A2O#1",
        state: :claimed
      )
    end.to raise_error(A3::Domain::ConfigurationError, "claimed scheduler task claims require claimed_by and claimed_at")
  end
end
