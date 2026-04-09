# frozen_string_literal: true

require_relative "show_output_formatter/formatting_helpers"
require_relative "show_output_formatter/task_formatter"
require_relative "show_output_formatter/run_formatter"
require_relative "show_output_formatter/blocked_diagnosis_formatter"
require_relative "show_output_formatter/scheduler_history_formatter"
require_relative "show_output_formatter/watch_summary_formatter"
require_relative "show_output_formatter/task_output"
require_relative "show_output_formatter/run_output"
require_relative "show_output_formatter/scheduler_output"

module A3
  module CLI
    module ShowOutputFormatter
      module_function

      def blocked_diagnosis_lines(result)
        RunOutput.blocked_diagnosis_lines(result)
      end

      def task_lines(task)
        TaskOutput.lines(task)
      end

      def run_lines(run)
        RunOutput.lines(run)
      end

      def scheduler_history_lines(history)
        SchedulerOutput.history_lines(history)
      end

      def watch_summary_lines(summary)
        WatchSummaryFormatter.lines(summary)
      end

      def format_diagnostic_value(value)
        FormattingHelpers.diagnostic_value(value)
      end
    end
  end
end
