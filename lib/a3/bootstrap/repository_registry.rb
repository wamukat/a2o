# frozen_string_literal: true

module A3
  module Bootstrap
    class RepositoryRegistry
      def self.build(task_repository:, run_repository:, storage_dir:)
        new(
          task_repository: task_repository,
          run_repository: run_repository,
          storage_dir: storage_dir
        ).build
      end

      def initialize(task_repository:, run_repository:, storage_dir:)
        @task_repository = task_repository
        @run_repository = run_repository
        @storage_dir = storage_dir
      end

      def build
        store = scheduler_store
        {
          storage_dir: @storage_dir,
          task_repository: @task_repository,
          run_repository: @run_repository,
          scheduler_state_repository: scheduler_state_repository(store),
          scheduler_cycle_repository: scheduler_cycle_repository(store)
        }.freeze
      end

      private

      def scheduler_store
        @scheduler_store ||=
          case @task_repository
          when A3::Infra::JsonTaskRepository
            A3::Infra::JsonSchedulerStore.new(File.join(@storage_dir, "scheduler_journal.json"))
          when A3::Infra::SqliteTaskRepository
            A3::Infra::SqliteSchedulerStore.new(File.join(@storage_dir, "a3.sqlite3"))
          else
            A3::Infra::InMemorySchedulerStore.new
          end
      end

      def scheduler_state_repository(store)
        case store
        when A3::Infra::JsonSchedulerStore
          A3::Infra::JsonSchedulerStateRepository.new(store)
        when A3::Infra::SqliteSchedulerStore
          A3::Infra::SqliteSchedulerStateRepository.new(store)
        else
          A3::Infra::InMemorySchedulerStateRepository.new(store)
        end
      end

      def scheduler_cycle_repository(store)
        case store
        when A3::Infra::JsonSchedulerStore
          A3::Infra::JsonSchedulerCycleRepository.new(store)
        when A3::Infra::SqliteSchedulerStore
          A3::Infra::SqliteSchedulerCycleRepository.new(store)
        else
          A3::Infra::InMemorySchedulerCycleRepository.new(store)
        end
      end
    end
  end
end
