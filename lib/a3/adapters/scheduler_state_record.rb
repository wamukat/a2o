# frozen_string_literal: true

module A3
  module Adapters
    module SchedulerStateRecord
      module_function

      def dump(state)
        {
          "paused" => state.paused,
          "last_stop_reason" => state.last_stop_reason&.to_s,
          "last_executed_count" => state.last_executed_count
        }
      end

      def load(record)
        A3::Domain::SchedulerState.new(
          paused: record.fetch("paused"),
          last_stop_reason: record["last_stop_reason"],
          last_executed_count: record.fetch("last_executed_count")
        )
      end
    end
  end
end
