# frozen_string_literal: true

module A3
  module Domain
    module SchedulerStateRepository
      def fetch
        raise NotImplementedError, "#{self.class} must implement #fetch"
      end

      def save(_state)
        raise NotImplementedError, "#{self.class} must implement #save"
      end

      def record_cycle_result(next_state:, cycle:)
        raise NotImplementedError, "#{self.class} must implement #record_cycle_result"
      end
    end
  end
end
