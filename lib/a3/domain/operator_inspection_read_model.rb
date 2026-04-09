# frozen_string_literal: true

module A3
  module Domain
    class OperatorInspectionReadModel
      def self.from_task(task:, tasks:)
        TaskInspection.from_task(task: task, tasks: tasks)
      end

      def self.from_run(run, recovery:)
        RunInspection.from_run(run, recovery: recovery)
      end

      def self.from_cycles(cycles)
        SchedulerInspection.from_cycles(cycles)
      end
    end
  end
end

require_relative "operator_inspection_read_model/task_models"
require_relative "operator_inspection_read_model/run_models"
require_relative "operator_inspection_read_model/scheduler_models"
