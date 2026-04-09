# frozen_string_literal: true

module A3
  module Application
    class SchedulerStoreBinding
      def self.shared_store_for(state_repository:, cycle_repository:)
        state_store = scheduler_store_for(state_repository)
        cycle_store = scheduler_store_for(cycle_repository)

        return nil if state_store.nil? || cycle_store.nil?
        return state_store if state_store.equal?(cycle_store)

        raise ArgumentError, "scheduler state and cycle repositories must share the same scheduler store"
      end

      def self.scheduler_store_for(repository)
        return nil unless repository
        return repository.scheduler_store if repository.respond_to?(:scheduler_store)

        raise ArgumentError, "#{repository.class} must expose a scheduler store"
      end

      private_class_method :scheduler_store_for
    end
  end
end
