# frozen_string_literal: true

require "a3/domain/scheduler_cycle"

module A3
  module Adapters
    module SchedulerCycleRecord
      module_function

      def dump(cycle)
        cycle.persisted_form
      end

      def load(record)
        A3::Domain::SchedulerCycle.from_persisted_form(record)
      end
    end
  end
end
