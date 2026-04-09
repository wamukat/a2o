# frozen_string_literal: true

module A3
  module Application
    class SchedulerCycleExecutor
      Result = Struct.new(:executions, :executed_count, :idle_reached, :paused_reached, keyword_init: true)

      def initialize(execute_next_runnable_task:, paused_checker: nil)
        @execute_next_runnable_task = execute_next_runnable_task
        @paused_checker = paused_checker || -> { false }
      end

      def call(project_context:, max_steps:)
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
    end
  end
end
