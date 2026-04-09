# frozen_string_literal: true

require "json"
require "fileutils"
require "a3/adapters/scheduler_state_record"
require "a3/adapters/scheduler_cycle_record"

module A3
  module Infra
    class JsonSchedulerStore
      def initialize(path)
        @path = path
      end

      def fetch_state
        payload = load_payload
        A3::Adapters::SchedulerStateRecord.load(payload.fetch("state"))
      end

      def save_state(state)
        payload = load_payload
        payload["state"] = A3::Adapters::SchedulerStateRecord.dump(state)
        write_payload(payload)
      end

      def all_cycles
        load_payload.fetch("cycles").map do |record|
          A3::Adapters::SchedulerCycleRecord.load(record)
        end
      end

      def append_cycle(cycle)
        payload = load_payload
        stored_cycle = cycle.cycle_number ? cycle : cycle.with_cycle_number(next_cycle_number(payload))
        payload.fetch("cycles") << A3::Adapters::SchedulerCycleRecord.dump(stored_cycle)
        write_payload(payload)
        stored_cycle
      end

      def record_cycle_result(next_state:, cycle:)
        payload = load_payload
        stored_cycle = cycle.cycle_number ? cycle : cycle.with_cycle_number(next_cycle_number(payload))
        payload["state"] = A3::Adapters::SchedulerStateRecord.dump(next_state)
        payload.fetch("cycles") << A3::Adapters::SchedulerCycleRecord.dump(stored_cycle)
        write_payload(payload)
        stored_cycle
      end

      private

      def load_payload
        return default_payload unless File.exist?(@path)

        parsed = JSON.parse(File.read(@path))
        {
          "state" => parsed.fetch("state"),
          "cycles" => parsed.fetch("cycles", [])
        }
      end

      def write_payload(payload)
        FileUtils.mkdir_p(File.dirname(@path))
        temp_path = "#{@path}.tmp"
        File.open(temp_path, "w") do |file|
          file.write(JSON.pretty_generate(payload))
          file.flush
          file.fsync
        end
        File.rename(temp_path, @path)
      ensure
        FileUtils.rm_f(temp_path) if defined?(temp_path) && File.exist?(temp_path)
      end

      def default_payload
        {
          "state" => A3::Adapters::SchedulerStateRecord.dump(A3::Domain::SchedulerState.new),
          "cycles" => []
        }
      end

      def next_cycle_number(payload)
        payload.fetch("cycles").map { |record| Integer(record.fetch("cycle_number")) }.max.to_i + 1
      end
    end
  end
end
