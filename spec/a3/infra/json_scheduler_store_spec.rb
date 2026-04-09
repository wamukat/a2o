# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Infra::JsonSchedulerStore do
  it "keeps the previous persisted payload when atomic cycle recording fails before replace" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "scheduler_journal.json")
      previous_state = A3::Domain::SchedulerState.new(
        paused: false,
        last_stop_reason: :idle,
        last_executed_count: 1
      )

      seed_store = described_class.new(path)
      seed_store.save_state(previous_state)
      persisted_cycle = seed_store.append_cycle(
        A3::Domain::SchedulerCycle.new(
          executed_count: 1,
          idle_reached: true,
          stop_reason: :idle,
          quarantined_count: 0
        )
      )

      failing_store = Class.new(described_class) do
        private

        def write_payload(_payload)
          raise "replace boom"
        end
      end.new(path)

      next_state = A3::Domain::SchedulerState.new(
        paused: true,
        last_stop_reason: :max_steps,
        last_executed_count: 9
      )
      next_cycle = A3::Domain::SchedulerCycle.new(
        executed_count: 9,
        idle_reached: false,
        stop_reason: :max_steps,
        quarantined_count: 2
      )

      expect do
        failing_store.record_cycle_result(next_state: next_state, cycle: next_cycle)
      end.to raise_error("replace boom")

      reloaded_store = described_class.new(path)
      expect(reloaded_store.fetch_state).to eq(previous_state)
      expect(reloaded_store.all_cycles).to eq([persisted_cycle])
    end
  end
end
