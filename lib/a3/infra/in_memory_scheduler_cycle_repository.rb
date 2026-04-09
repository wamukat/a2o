# frozen_string_literal: true

require "a3/domain/scheduler_cycle_repository"
require "a3/infra/in_memory_scheduler_store"

module A3
  module Infra
    class InMemorySchedulerCycleRepository
      include A3::Domain::SchedulerCycleRepository
      attr_reader :scheduler_store

      def initialize(store = A3::Infra::InMemorySchedulerStore.new)
        @scheduler_store = store
      end

      def append(cycle)
        scheduler_store.append_cycle(cycle)
      end

      def all
        scheduler_store.all_cycles.dup.freeze
      end
    end
  end
end
