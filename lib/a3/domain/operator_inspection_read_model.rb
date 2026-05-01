# frozen_string_literal: true

module A3
  module Domain
    class OperatorInspectionReadModel
      def self.from_task(task:, tasks:, skill_feedback: [], claim_ref: nil)
        kwargs = { task: task, tasks: tasks }
        kwargs[:skill_feedback] = skill_feedback unless Array(skill_feedback).empty?
        kwargs[:claim_ref] = claim_ref if claim_ref
        TaskInspection.from_task(**kwargs)
      end

      def self.from_run(run, recovery:, claim_ref: nil)
        kwargs = { recovery: recovery }
        kwargs[:claim_ref] = claim_ref if claim_ref
        RunInspection.from_run(run, **kwargs)
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
