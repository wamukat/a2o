# frozen_string_literal: true

module A3
  module Application
    class ShowSchedulerState
      def initialize(scheduler_state_repository:)
        @scheduler_state_repository = scheduler_state_repository
      end

      def call
        A3::Domain::OperatorInspectionReadModel::SchedulerStateView.from_state(
          @scheduler_state_repository.fetch
        )
      end
    end

    class PauseScheduler
      def initialize(scheduler_state_repository:)
        @scheduler_state_repository = scheduler_state_repository
      end

      def call
        state = @scheduler_state_repository.fetch.pause
        @scheduler_state_repository.save(state)
        state
      end
    end

    class ResumeScheduler
      def initialize(scheduler_state_repository:)
        @scheduler_state_repository = scheduler_state_repository
      end

      def call
        state = @scheduler_state_repository.fetch.resume
        @scheduler_state_repository.save(state)
        state
      end
    end
  end
end
