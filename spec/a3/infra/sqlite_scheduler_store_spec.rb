# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Infra::SqliteSchedulerStore do
  it "rolls back state update when cycle persistence fails" do
    Dir.mktmpdir do |dir|
      store = described_class.new(File.join(dir, "a3.sqlite3"))
      previous_state = A3::Domain::SchedulerState.new(
        paused: false,
        last_stop_reason: :idle,
        last_executed_count: 1
      )
      store.save_state(previous_state)
      persisted_cycle = store.append_cycle(
        A3::Domain::SchedulerCycle.new(
          executed_count: 1,
          idle_reached: true,
          stop_reason: :idle,
          quarantined_count: 0
        )
      )

      next_state = A3::Domain::SchedulerState.new(
        paused: true,
        last_stop_reason: :max_steps,
        last_executed_count: 9
      )
      duplicate_cycle = A3::Domain::SchedulerCycle.new(
        cycle_number: persisted_cycle.cycle_number,
        executed_count: 9,
        idle_reached: false,
        stop_reason: :max_steps,
        quarantined_count: 2
      )

      expect do
        store.record_cycle_result(next_state: next_state, cycle: duplicate_cycle)
      end.to raise_error(SQLite3::ConstraintException)

      expect(store.fetch_state).to eq(previous_state)
      expect(store.all_cycles).to eq([persisted_cycle])
    end
  end
end
