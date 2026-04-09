# frozen_string_literal: true

require "a3/infra/in_memory_scheduler_cycle_repository"
require "a3/domain/scheduler_cycle"

RSpec.describe A3::Infra::InMemorySchedulerCycleRepository do
  it "appends cycles with ascending cycle numbers" do
    repository = described_class.new

    first = repository.append(
      A3::Domain::SchedulerCycle.new(
        executed_count: 3,
        idle_reached: false,
        stop_reason: :max_steps,
        quarantined_count: 0
      )
    )
    second = repository.append(
      A3::Domain::SchedulerCycle.new(
        executed_count: 1,
        idle_reached: true,
        stop_reason: :idle,
        quarantined_count: 2
      )
    )

    expect(first.cycle_number).to eq(1)
    expect(second.cycle_number).to eq(2)
    expect(repository.all).to eq([first, second])
  end
end
