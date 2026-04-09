# frozen_string_literal: true

require_relative "scheduler_store_binding"

module A3
  module Application
    class SchedulerCycleJournal
      def initialize(scheduler_state_repository:, scheduler_cycle_repository:)
        @scheduler_state_repository = scheduler_state_repository
        @scheduler_cycle_repository = scheduler_cycle_repository
        @scheduler_store = A3::Application::SchedulerStoreBinding.shared_store_for(
          state_repository: scheduler_state_repository,
          cycle_repository: scheduler_cycle_repository
        )
      end

      def paused?
        @scheduler_state_repository && @scheduler_state_repository.fetch.paused
      end

      def record(result)
        return build_cycle(result) unless @scheduler_state_repository

        next_state = current_state.record_cycle(
          stop_reason: result.stop_reason,
          executed_count: result.executed_count
        )
        cycle = build_cycle(result)

        @scheduler_state_repository.record_cycle_result(
          next_state: next_state,
          cycle: cycle
        )
      end

      private

      def current_state
        return nil unless @scheduler_state_repository

        @scheduler_state_repository.fetch
      end

      def build_cycle(result)
        return nil unless @scheduler_cycle_repository

        A3::Domain::SchedulerCycle.from_execute_until_idle_result(result)
      end
    end
  end
end
