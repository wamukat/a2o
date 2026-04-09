# frozen_string_literal: true

module A3
  module Application
    class ShowSchedulerHistory
      def initialize(scheduler_cycle_repository:)
        @scheduler_cycle_repository = scheduler_cycle_repository
      end

      def call
        A3::Domain::OperatorInspectionReadModel::SchedulerHistory.from_cycles(
          @scheduler_cycle_repository.all
        )
      end
    end
  end
end
