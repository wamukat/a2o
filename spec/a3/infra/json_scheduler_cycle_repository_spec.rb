# frozen_string_literal: true

require "tmpdir"
require "a3/infra/json_scheduler_cycle_repository"
require "a3/domain/scheduler_cycle"

RSpec.describe A3::Infra::JsonSchedulerCycleRepository do
  it "round-trips append-only cycles" do
    Dir.mktmpdir do |dir|
      repository = described_class.new(File.join(dir, "scheduler_cycles.json"))
      cycle = A3::Domain::SchedulerCycle.new(
        executed_count: 2,
        idle_reached: true,
        stop_reason: :idle,
        quarantined_count: 1
      )

      appended = repository.append(cycle)
      reloaded = described_class.new(File.join(dir, "scheduler_cycles.json"))

      expect(appended.cycle_number).to eq(1)
      expect(reloaded.all).to eq([appended])
    end
  end
end
