# frozen_string_literal: true

require_relative "scheduler_cycle_executor"
require_relative "scheduler_loop_policy"

module A3
  module Application
    class SchedulerLoop
      Result = Struct.new(:executions, :executed_count, :idle_reached, :stop_reason, :quarantined_count, :scheduler_cycle, keyword_init: true)

      def initialize(execute_next_runnable_task:, cycle_journal:, quarantine_runner:)
        @cycle_journal = cycle_journal
        @quarantine_runner = quarantine_runner
        @cycle_executor = A3::Application::SchedulerCycleExecutor.new(
          execute_next_runnable_task: execute_next_runnable_task,
          paused_checker: -> { @cycle_journal.paused? }
        )
        @loop_policy = A3::Application::SchedulerLoopPolicy.new
      end

      def call(project_context:, max_steps: 100)
        if @cycle_journal.paused?
          paused_result = @loop_policy.paused_result
          return Result.new(
            executions: paused_result.executions,
            executed_count: paused_result.executed_count,
            idle_reached: paused_result.idle_reached,
            stop_reason: paused_result.stop_reason,
            quarantined_count: paused_result.quarantined_count,
            scheduler_cycle: nil
          )
        end
        cycle_result = @cycle_executor.call(project_context: project_context, max_steps: max_steps)
        quarantined_count = cycle_result.idle_reached ? @quarantine_runner.call : 0
        result = @loop_policy.result_for(
          cycle_result: cycle_result,
          quarantined_count: quarantined_count
        )
        result = Result.new(
          executions: result.executions,
          executed_count: result.executed_count,
          idle_reached: result.idle_reached,
          stop_reason: result.stop_reason,
          quarantined_count: result.quarantined_count,
          scheduler_cycle: nil
        )
        cycle = @cycle_journal.record(result)
        Result.new(
          executions: result.executions,
          executed_count: result.executed_count,
          idle_reached: result.idle_reached,
          stop_reason: result.stop_reason,
          quarantined_count: result.quarantined_count,
          scheduler_cycle: cycle
        )
      end
    end
  end
end
