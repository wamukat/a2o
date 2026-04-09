# frozen_string_literal: true

module A3
  module Bootstrap
    class Session
      SUPPORTED_STORAGE_BACKENDS = %i[json sqlite].freeze

      attr_reader :manifest_path, :preset_dir, :storage_dir, :storage_backend, :project_surface, :project_context, :container, :runtime_package, :runtime_environment_config

      def self.build(manifest_path:, preset_dir:, storage_backend:, storage_dir:, run_id_generator:, command_runner: A3::Infra::LocalCommandRunner.new, merge_runner: A3::Infra::LocalMergeRunner.new, worker_gateway: nil, repo_sources: {}, external_task_source: A3::Infra::NullExternalTaskSource.new, external_task_status_publisher: A3::Infra::NullExternalTaskStatusPublisher.new, external_task_activity_publisher: A3::Infra::NullExternalTaskActivityPublisher.new, external_follow_up_child_writer: nil, image_version: ENV.fetch("A3_IMAGE_VERSION", "dev"))
        build_session(
          manifest_path: manifest_path,
          preset_dir: preset_dir,
          storage_backend: normalize_storage_backend!(storage_backend),
          storage_dir: storage_dir,
          run_id_generator: run_id_generator,
          command_runner: command_runner,
          merge_runner: merge_runner,
          worker_gateway: worker_gateway,
          repo_sources: repo_sources,
          external_task_source: external_task_source,
          external_task_status_publisher: external_task_status_publisher,
          external_task_activity_publisher: external_task_activity_publisher,
          external_follow_up_child_writer: external_follow_up_child_writer,
          image_version: image_version
        )
      end

      def self.json(manifest_path:, preset_dir:, storage_dir:, run_id_generator:, command_runner:, merge_runner:, worker_gateway:, repo_sources:, external_task_source: A3::Infra::NullExternalTaskSource.new, external_task_status_publisher: A3::Infra::NullExternalTaskStatusPublisher.new, external_task_activity_publisher: A3::Infra::NullExternalTaskActivityPublisher.new, external_follow_up_child_writer: nil, image_version: ENV.fetch("A3_IMAGE_VERSION", "dev"))
        build(
          manifest_path: manifest_path,
          preset_dir: preset_dir,
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
          external_follow_up_child_writer: external_follow_up_child_writer,
          image_version: image_version
        )
      end

      def self.sqlite(manifest_path:, preset_dir:, storage_dir:, run_id_generator:, command_runner:, merge_runner:, worker_gateway:, repo_sources:, external_task_source: A3::Infra::NullExternalTaskSource.new, external_task_status_publisher: A3::Infra::NullExternalTaskStatusPublisher.new, external_task_activity_publisher: A3::Infra::NullExternalTaskActivityPublisher.new, external_follow_up_child_writer: nil, image_version: ENV.fetch("A3_IMAGE_VERSION", "dev"))
        build(
          manifest_path: manifest_path,
          preset_dir: preset_dir,
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
          external_follow_up_child_writer: external_follow_up_child_writer,
          image_version: image_version
        )
      end

      def initialize(manifest_path:, preset_dir:, storage_dir:, storage_backend:, project_surface:, project_context:, container:, runtime_package:, runtime_environment_config:)
        @manifest_path = manifest_path
        @preset_dir = preset_dir
        @storage_dir = storage_dir
        @storage_backend = storage_backend.to_sym
        @project_surface = project_surface
        @project_context = project_context
        @container = container
        @runtime_package = runtime_package
        @runtime_environment_config = runtime_environment_config
        freeze
      end

      def self.build_session(manifest_path:, preset_dir:, storage_backend:, storage_dir:, run_id_generator:, command_runner:, merge_runner:, worker_gateway:, repo_sources:, external_task_source:, external_task_status_publisher:, external_task_activity_publisher:, external_follow_up_child_writer:, image_version:)
        runtime_package = A3::Bootstrap.runtime_package_descriptor(
          manifest_path: manifest_path,
          preset_dir: preset_dir,
          storage_backend: storage_backend,
          storage_dir: storage_dir,
          repo_sources: repo_sources,
          image_version: image_version
        )
        project_surface = A3::Bootstrap.project_surface(manifest_path: manifest_path, preset_dir: preset_dir)
        project_context = A3::Bootstrap.project_context(manifest_path: manifest_path, preset_dir: preset_dir)
        container = A3::Bootstrap.container(
          storage_backend: storage_backend,
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
        runtime_environment_config = A3::Bootstrap::RuntimeEnvironmentConfig.build(
          runtime_package: runtime_package,
          project_surface: project_surface,
          project_context: project_context,
          container: container
        )
        new(
          manifest_path: manifest_path,
          preset_dir: preset_dir,
          storage_dir: storage_dir,
          storage_backend: storage_backend,
          project_surface: project_surface,
          project_context: project_context,
          container: container,
          runtime_package: runtime_package,
          runtime_environment_config: runtime_environment_config
        )
      end

      def self.normalize_storage_backend!(storage_backend)
        normalized_backend = storage_backend.to_sym
        return normalized_backend if SUPPORTED_STORAGE_BACKENDS.include?(normalized_backend)

        raise ArgumentError, "unsupported storage backend: #{storage_backend}"
      end

      private_class_method :build_session
      private_class_method :normalize_storage_backend!
    end
  end
end
