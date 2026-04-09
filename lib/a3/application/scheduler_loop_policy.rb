# frozen_string_literal: true

module A3
  module Application
    class SchedulerLoopPolicy
      Result = Struct.new(:executions, :executed_count, :idle_reached, :stop_reason, :quarantined_count, keyword_init: true)

      def paused_result
        Result.new(
          executions: [].freeze,
          executed_count: 0,
          idle_reached: false,
          stop_reason: :paused,
          quarantined_count: 0
        )
      end

      def result_for(cycle_result:, quarantined_count:)
        Result.new(
          executions: cycle_result.executions,
          executed_count: cycle_result.executed_count,
          idle_reached: cycle_result.idle_reached,
          stop_reason: stop_reason_for(cycle_result: cycle_result),
          quarantined_count: quarantined_count
        )
      end

      private

      def stop_reason_for(cycle_result:)
        return :paused if cycle_result.paused_reached
        return :idle if cycle_result.idle_reached

        :max_steps
      end
    end
  end
end
