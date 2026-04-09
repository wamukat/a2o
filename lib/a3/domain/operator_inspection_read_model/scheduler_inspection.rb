# frozen_string_literal: true

module A3
  module Domain
    class OperatorInspectionReadModel
      module SchedulerInspection
        module_function

        def from_cycles(cycles)
          SchedulerHistory.from_cycles(cycles)
        end
      end
    end
  end
end
