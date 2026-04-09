# frozen_string_literal: true

module A3
  module Domain
    class SchedulerCycleStep
      attr_reader :task_ref, :phase

      def initialize(task_ref:, phase:)
        @task_ref = task_ref
        @phase = phase.to_sym
        freeze
      end

      def self.from_execution(execution)
        new(
          task_ref: execution.task.ref,
          phase: execution.phase
        )
      end

      def self.from_persisted_form(record)
        new(
          task_ref: record.fetch("task_ref"),
          phase: record.fetch("phase")
        )
      end

      def persisted_form
        {
          "task_ref" => task_ref,
          "phase" => phase.to_s
        }
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.task_ref == task_ref &&
          other.phase == phase
      end
      alias eql? ==
    end
  end
end
