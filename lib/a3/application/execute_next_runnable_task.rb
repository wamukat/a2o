# frozen_string_literal: true

module A3
  module Application
    class ExecuteNextRunnableTask
      Result = Struct.new(:task, :phase, :started_run, :execution_result, keyword_init: true)

      def initialize(schedule_next_run:, run_worker_phase:, run_verification:, run_merge:)
        @schedule_next_run = schedule_next_run
        @run_worker_phase = run_worker_phase
        @run_verification = run_verification
        @run_merge = run_merge
      end

      def call(project_context:)
        scheduled = @schedule_next_run.call(project_context: project_context)
        return Result.new(task: nil, phase: nil, started_run: nil, execution_result: nil) unless scheduled.task

        execution_result = execute_phase(
          task_ref: scheduled.task.ref,
          run_ref: scheduled.started_run.run.ref,
          phase: scheduled.phase,
          project_context: project_context
        )

        Result.new(
          task: scheduled.task,
          phase: scheduled.phase,
          started_run: scheduled.started_run,
          execution_result: execution_result
        )
      end

      private

      def execute_phase(task_ref:, run_ref:, phase:, project_context:)
        case phase.to_sym
        when :implementation, :review
          @run_worker_phase.call(task_ref: task_ref, run_ref: run_ref, project_context: project_context)
        when :verification
          @run_verification.call(task_ref: task_ref, run_ref: run_ref, project_context: project_context)
        when :merge
          @run_merge.call(task_ref: task_ref, run_ref: run_ref, project_context: project_context)
        else
          raise A3::Domain::InvalidPhaseError, "unsupported phase #{phase}"
        end
      end
    end
  end
end
