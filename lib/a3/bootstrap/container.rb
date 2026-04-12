# frozen_string_literal: true

module A3
  module Bootstrap
    class Container
      def self.build(storage_backend:, storage_dir:, run_id_generator:, command_runner: A3::Infra::LocalCommandRunner.new, merge_runner: A3::Infra::DisabledMergeRunner.new, worker_gateway: nil, repo_sources: {}, external_task_source: A3::Infra::NullExternalTaskSource.new, external_task_status_publisher: A3::Infra::NullExternalTaskStatusPublisher.new, external_task_activity_publisher: A3::Infra::NullExternalTaskActivityPublisher.new, external_follow_up_child_writer: nil)
        new(
          **repositories_for(storage_backend: storage_backend, storage_dir: storage_dir),
          run_id_generator: run_id_generator,
          command_runner: command_runner,
          merge_runner: merge_runner,
          worker_gateway: worker_gateway,
          storage_dir: storage_dir,
          repo_sources: repo_sources,
          external_task_source: external_task_source,
          external_task_status_publisher: external_task_status_publisher,
          external_task_activity_publisher: external_task_activity_publisher,
          external_follow_up_child_writer: external_follow_up_child_writer
        ).build
      end

      def self.json(storage_dir:, run_id_generator:, command_runner: A3::Infra::LocalCommandRunner.new, merge_runner: A3::Infra::DisabledMergeRunner.new, worker_gateway: nil, repo_sources: {}, external_task_source: A3::Infra::NullExternalTaskSource.new, external_task_status_publisher: A3::Infra::NullExternalTaskStatusPublisher.new, external_task_activity_publisher: A3::Infra::NullExternalTaskActivityPublisher.new, external_follow_up_child_writer: nil)
        build(
          storage_backend: :json,
          storage_dir: storage_dir,
          run_id_generator: run_id_generator,
          command_runner: command_runner,
          merge_runner: merge_runner,
          worker_gateway: worker_gateway,
          repo_sources: repo_sources,
          external_task_source: external_task_source,
          external_task_status_publisher: external_task_status_publisher,
          external_task_activity_publisher: external_task_activity_publisher,
          external_follow_up_child_writer: external_follow_up_child_writer
        )
      end

      def self.sqlite(storage_dir:, run_id_generator:, command_runner: A3::Infra::LocalCommandRunner.new, merge_runner: A3::Infra::DisabledMergeRunner.new, worker_gateway: nil, repo_sources: {}, external_task_source: A3::Infra::NullExternalTaskSource.new, external_task_status_publisher: A3::Infra::NullExternalTaskStatusPublisher.new, external_task_activity_publisher: A3::Infra::NullExternalTaskActivityPublisher.new, external_follow_up_child_writer: nil)
        build(
          storage_backend: :sqlite,
          storage_dir: storage_dir,
          run_id_generator: run_id_generator,
          command_runner: command_runner,
          merge_runner: merge_runner,
          worker_gateway: worker_gateway,
          repo_sources: repo_sources,
          external_task_source: external_task_source,
          external_task_status_publisher: external_task_status_publisher,
          external_task_activity_publisher: external_task_activity_publisher,
          external_follow_up_child_writer: external_follow_up_child_writer
        )
      end

      def initialize(task_repository:, run_repository:, run_id_generator:, command_runner:, merge_runner:, worker_gateway:, storage_dir:, repo_sources:, external_task_source: A3::Infra::NullExternalTaskSource.new, external_task_status_publisher: A3::Infra::NullExternalTaskStatusPublisher.new, external_task_activity_publisher: A3::Infra::NullExternalTaskActivityPublisher.new, external_follow_up_child_writer: nil)
        @task_repository = task_repository
        @run_repository = run_repository
        @run_id_generator = run_id_generator
        @command_runner = command_runner
        @merge_runner = merge_runner
        @worker_gateway = worker_gateway || A3::Infra::LocalWorkerGateway.new(command_runner: command_runner)
        @storage_dir = storage_dir
        @repo_sources = repo_sources
        @external_task_source = external_task_source
        @external_task_status_publisher = external_task_status_publisher
        @external_task_activity_publisher = external_task_activity_publisher
        @external_follow_up_child_writer = external_follow_up_child_writer
      end

      def build
        repositories = A3::Bootstrap::RepositoryRegistry.build(
          task_repository: @task_repository,
          run_repository: @run_repository,
          storage_dir: @storage_dir
        )
        runtime_services = A3::Bootstrap::RuntimeServicesBuilder.build(
          repositories: repositories,
          run_id_generator: @run_id_generator,
          command_runner: @command_runner,
          merge_runner: @merge_runner,
          worker_gateway: @worker_gateway,
          storage_dir: @storage_dir,
          repo_sources: @repo_sources,
          external_task_source: @external_task_source,
          external_task_status_publisher: @external_task_status_publisher,
          external_task_activity_publisher: @external_task_activity_publisher,
          external_follow_up_child_writer: @external_follow_up_child_writer
        )

        A3::Bootstrap::ContainerBuilder.build(
          repositories: repositories,
          runtime_services: runtime_services
        )
      end

      def self.repositories_for(storage_backend:, storage_dir:)
        case storage_backend.to_sym
        when :json
          {
            task_repository: A3::Infra::JsonTaskRepository.new(File.join(storage_dir, "tasks.json")),
            run_repository: A3::Infra::JsonRunRepository.new(File.join(storage_dir, "runs.json"))
          }
        when :sqlite
          db_path = File.join(storage_dir, "a3.sqlite3")
          {
            task_repository: A3::Infra::SqliteTaskRepository.new(db_path),
            run_repository: A3::Infra::SqliteRunRepository.new(db_path)
          }
        else
          raise ArgumentError, "unsupported storage backend: #{storage_backend}"
        end
      end
      private_class_method :repositories_for
    end
  end
end
