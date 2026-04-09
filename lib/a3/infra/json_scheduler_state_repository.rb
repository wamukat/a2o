# frozen_string_literal: true

require "json"
require "fileutils"
require "a3/infra/json_scheduler_store"

module A3
  module Infra
    class JsonSchedulerStateRepository
      include A3::Domain::SchedulerStateRepository
      attr_reader :scheduler_store

      def initialize(path_or_store)
        @scheduler_store = path_or_store.respond_to?(:fetch_state) ? path_or_store : A3::Infra::JsonSchedulerStore.new(path_or_store)
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
