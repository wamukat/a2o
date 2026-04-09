# frozen_string_literal: true

RSpec.describe A3::Domain::SchedulerState do
  it "starts active by default" do
    state = described_class.new

    expect(state.paused).to eq(false)
    expect(state.last_stop_reason).to be_nil
    expect(state.last_executed_count).to eq(0)
  end

  it "returns a paused copy" do
    state = described_class.new.pause

    expect(state.paused).to eq(true)
  end

  it "returns a resumed copy" do
    state = described_class.new(paused: true).resume

    expect(state.paused).to eq(false)
  end

  it "records a completed cycle immutably" do
    state = described_class.new.record_cycle(stop_reason: :idle, executed_count: 4)

    expect(state.last_stop_reason).to eq(:idle)
    expect(state.last_executed_count).to eq(4)
  end
end
