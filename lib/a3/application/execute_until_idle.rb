# frozen_string_literal: true

require_relative "scheduler_cycle_journal"
require_relative "scheduler_quarantine_runner"
require_relative "scheduler_loop"

module A3
  module Application
    class ExecuteUntilIdle
      Result = SchedulerLoop::Result

      def initialize(execute_next_runnable_task:, cycle_journal:, quarantine_terminal_task_workspaces:)
        @scheduler_loop = A3::Application::SchedulerLoop.new(
          execute_next_runnable_task: execute_next_runnable_task,
          cycle_journal: cycle_journal,
          quarantine_runner: A3::Application::SchedulerQuarantineRunner.new(
            quarantine_terminal_task_workspaces: quarantine_terminal_task_workspaces
          )
        )
      end

      def call(project_context:, max_steps: 100)
        @scheduler_loop.call(project_context: project_context, max_steps: max_steps)
      end
    end
  end
end
