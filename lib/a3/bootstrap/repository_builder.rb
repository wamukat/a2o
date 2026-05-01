# frozen_string_literal: true

module A3
  module Bootstrap
    class RepositoryBuilder
      def initialize(task_repository:, run_repository:, storage_dir:)
        @task_repository = task_repository
        @run_repository = run_repository
        @storage_dir = storage_dir
      end

      def build
        store = scheduler_store
        {
          task_repository: task_repository,
          run_repository: run_repository,
          task_metrics_repository: task_metrics_repository,
          scheduler_state_repository: scheduler_state_repository(store),
          scheduler_cycle_repository: scheduler_cycle_repository(store),
          task_claim_repository: task_claim_repository,
          shared_ref_lock_repository: A3::Infra::InMemorySharedRefLockRepository.new
        }
      end

      private

      attr_reader :task_repository, :run_repository, :storage_dir

      def scheduler_store
        @scheduler_store ||=
          case task_repository
          when A3::Infra::JsonTaskRepository
            A3::Infra::JsonSchedulerStore.new(File.join(storage_dir, "scheduler_journal.json"))
          when A3::Infra::SqliteTaskRepository
            A3::Infra::SqliteSchedulerStore.new(File.join(storage_dir, "a3.sqlite3"))
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

      def task_metrics_repository
        case task_repository
        when A3::Infra::JsonTaskRepository
          A3::Infra::JsonTaskMetricsRepository.new(File.join(storage_dir, "task_metrics.json"))
        when A3::Infra::SqliteTaskRepository
          A3::Infra::SqliteTaskMetricsRepository.new(File.join(storage_dir, "a3.sqlite3"))
        else
          A3::Infra::InMemoryTaskMetricsRepository.new
        end
      end

      def task_claim_repository
        case task_repository
        when A3::Infra::JsonTaskRepository
          A3::Infra::JsonSchedulerTaskClaimRepository.new(File.join(storage_dir, "scheduler_task_claims.json"))
        when A3::Infra::SqliteTaskRepository
          A3::Infra::SqliteSchedulerTaskClaimRepository.new(File.join(storage_dir, "a3.sqlite3"))
        else
          A3::Infra::InMemorySchedulerTaskClaimRepository.new
        end
      end
    end
  end
end
