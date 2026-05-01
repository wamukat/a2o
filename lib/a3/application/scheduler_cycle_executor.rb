# frozen_string_literal: true

module A3
  module Application
    class SchedulerCycleExecutor
      Result = Struct.new(:executions, :executed_count, :idle_reached, :paused_reached, keyword_init: true)

      def initialize(execute_next_runnable_task:, execute_runnable_task_batch: nil, paused_checker: nil)
        @execute_next_runnable_task = execute_next_runnable_task
        @execute_runnable_task_batch = execute_runnable_task_batch
        @paused_checker = paused_checker || -> { false }
      end

      def call(project_context:, max_steps:)
        return execute_parallel(project_context: project_context, max_steps: max_steps) if parallel_enabled?(project_context)

        executions = []
        idle_reached = false
        paused_reached = false

        max_steps.times do
          execution = @execute_next_runnable_task.call(project_context: project_context)
          if execution.task.nil?
            idle_reached = true
            break
          end

          executions << execution
          if @paused_checker.call
            paused_reached = true
            break
          end
        end

        Result.new(
          executions: executions.freeze,
          executed_count: executions.size,
          idle_reached: idle_reached,
          paused_reached: paused_reached
        )
      end

      private

      def parallel_enabled?(project_context)
        @execute_runnable_task_batch &&
          project_context.surface.scheduler_config.max_parallel_tasks > 1
      end

      def execute_parallel(project_context:, max_steps:)
        executions = []
        idle_reached = false
        paused_reached = false

        while executions.size < max_steps
          remaining_steps = max_steps - executions.size
          batch_result = @execute_runnable_task_batch.call(
            project_context: project_context,
            max_steps: remaining_steps
          )
          batch_executions = batch_result.executions
          if batch_executions.empty?
            idle_reached = batch_result.idle?
            break
          end

          executions.concat(batch_executions)
          if @paused_checker.call
            paused_reached = true
            break
          end
        end

        Result.new(
          executions: executions.freeze,
          executed_count: executions.size,
          idle_reached: idle_reached,
          paused_reached: paused_reached
        )
      end
    end
  end
end
