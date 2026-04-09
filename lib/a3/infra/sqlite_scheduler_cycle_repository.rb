# frozen_string_literal: true

require "fileutils"
require "json"
require "sqlite3"
require "a3/domain/scheduler_cycle_repository"
require "a3/adapters/scheduler_cycle_record"
require "a3/infra/sqlite_scheduler_store"

module A3
  module Infra
    class SqliteSchedulerCycleRepository
      include A3::Domain::SchedulerCycleRepository
      attr_reader :scheduler_store

      def initialize(path_or_store)
        @scheduler_store = path_or_store.respond_to?(:all_cycles) ? path_or_store : A3::Infra::SqliteSchedulerStore.new(path_or_store)
      end

      def append(cycle)
        scheduler_store.append_cycle(cycle)
      end

      def all
        scheduler_store.all_cycles
      end
    end
  end
end
