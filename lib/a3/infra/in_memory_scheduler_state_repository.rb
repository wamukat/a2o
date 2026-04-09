# frozen_string_literal: true

require "a3/infra/in_memory_scheduler_store"

module A3
  module Infra
    class InMemorySchedulerStateRepository
      include A3::Domain::SchedulerStateRepository
      attr_reader :scheduler_store

      def initialize(store = A3::Infra::InMemorySchedulerStore.new)
        @scheduler_store = store
      end

      def fetch
        scheduler_store.fetch_state
      end

      def save(state)
        scheduler_store.save_state(state)
      end

      def record_cycle_result(next_state:, cycle:)
        scheduler_store.record_cycle_result(next_state: next_state, cycle: cycle)
      end
    end
  end
end
