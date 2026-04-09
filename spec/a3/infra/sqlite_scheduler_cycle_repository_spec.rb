# frozen_string_literal: true

require "tmpdir"
require "a3/infra/sqlite_scheduler_cycle_repository"
require "a3/domain/scheduler_cycle"

RSpec.describe A3::Infra::SqliteSchedulerCycleRepository do
  it "round-trips append-only cycles" do
    Dir.mktmpdir do |dir|
      repository = described_class.new(File.join(dir, "a3.sqlite3"))
      first = repository.append(
        A3::Domain::SchedulerCycle.new(
          executed_count: 4,
          idle_reached: false,
          stop_reason: :max_steps,
          quarantined_count: 0
        )
      )
      second = repository.append(
        A3::Domain::SchedulerCycle.new(
          executed_count: 0,
          idle_reached: true,
          stop_reason: :idle,
          quarantined_count: 3
        )
      )
      reloaded = described_class.new(File.join(dir, "a3.sqlite3"))

      expect(first.cycle_number).to eq(1)
      expect(second.cycle_number).to eq(2)
      expect(reloaded.all).to eq([first, second])
    end
  end
end
