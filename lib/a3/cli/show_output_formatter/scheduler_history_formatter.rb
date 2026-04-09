# frozen_string_literal: true

module A3
  module CLI
    module ShowOutputFormatter
      module SchedulerHistoryFormatter
        module_function

        def lines(history)
          return ["scheduler history empty"] if history.empty?

          history.map do |cycle|
            line = "cycle=#{cycle.cycle_number} executed=#{cycle.executed_count} idle=#{cycle.idle_reached} stop_reason=#{cycle.stop_reason} quarantined=#{cycle.quarantined_count}"
            unless cycle.executed_steps.empty?
              line = "#{line} steps=#{cycle.executed_steps.map(&:summary).join(',')}"
            end
            line
          end
        end
      end
    end
  end
end
