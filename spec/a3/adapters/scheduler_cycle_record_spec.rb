# frozen_string_literal: true

require "a3/adapters/scheduler_cycle_record"
require "a3/domain/scheduler_cycle"

RSpec.describe A3::Adapters::SchedulerCycleRecord do
  it "round-trips a scheduler cycle payload" do
    cycle = A3::Domain::SchedulerCycle.new(
      cycle_number: 2,
      executed_count: 5,
      idle_reached: false,
      stop_reason: :max_steps,
      quarantined_count: 1
    )

    expect(described_class.load(described_class.dump(cycle))).to eq(cycle)
  end
end
