# frozen_string_literal: true

module A3
  module CLI
    module ShowOutputFormatter
      module SchedulerOutput
        module_function

        def history_lines(history)
          SchedulerHistoryFormatter.lines(history)
        end
      end
    end
  end
end
