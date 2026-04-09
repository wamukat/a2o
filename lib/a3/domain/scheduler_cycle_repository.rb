# frozen_string_literal: true

module A3
  module Domain
    module SchedulerCycleRepository
      # Append-only store for scheduler cycle history.
      def append(_cycle)
        raise NotImplementedError, "#{self.class} must implement #append"
      end

      def all
        raise NotImplementedError, "#{self.class} must implement #all"
      end
    end
  end
end
