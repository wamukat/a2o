# frozen_string_literal: true

require "yaml"

require_relative "bootstrap/container"
require_relative "bootstrap/container_builder"
require_relative "bootstrap/manifest_session"
require_relative "bootstrap/repository_registry"
require_relative "bootstrap/runtime_package_session"
require_relative "bootstrap/session"
require_relative "bootstrap/runtime_environment_config"
require_relative "bootstrap/runtime_services_builder"

module A3
  module Bootstrap
    module_function

    def container(storage_backend:, storage_dir:, run_id_generator:, command_runner: A3::Infra::LocalCommandRunner.new, merge_runner: A3::Infra::DisabledMergeRunner.new, worker_gateway: nil, repo_sources: {}, external_task_source: A3::Infra::NullExternalTaskSource.new, external_task_status_publisher: A3::Infra::NullExternalTaskStatusPublisher.new, external_task_activity_publisher: A3::Infra::NullExternalTaskActivityPublisher.new, external_follow_up_child_writer: nil)
      A3::Bootstrap::Container.build(
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
    end

    def json_container(storage_dir:, run_id_generator:, command_runner: A3::Infra::LocalCommandRunner.new, merge_runner: A3::Infra::DisabledMergeRunner.new, worker_gateway: nil, repo_sources: {}, external_task_source: A3::Infra::NullExternalTaskSource.new, external_task_status_publisher: A3::Infra::NullExternalTaskStatusPublisher.new, external_task_activity_publisher: A3::Infra::NullExternalTaskActivityPublisher.new, external_follow_up_child_writer: nil)
      container(
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

    def sqlite_container(storage_dir:, run_id_generator:, command_runner: A3::Infra::LocalCommandRunner.new, merge_runner: A3::Infra::DisabledMergeRunner.new, worker_gateway: nil, repo_sources: {}, external_task_source: A3::Infra::NullExternalTaskSource.new, external_task_status_publisher: A3::Infra::NullExternalTaskStatusPublisher.new, external_task_activity_publisher: A3::Infra::NullExternalTaskActivityPublisher.new, external_follow_up_child_writer: nil)
      container(
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

    def session(manifest_path:, preset_dir:, storage_backend:, storage_dir:, run_id_generator:, command_runner: A3::Infra::LocalCommandRunner.new, merge_runner: A3::Infra::DisabledMergeRunner.new, worker_gateway: nil, repo_sources: {}, external_task_source: A3::Infra::NullExternalTaskSource.new, external_task_status_publisher: A3::Infra::NullExternalTaskStatusPublisher.new, external_task_activity_publisher: A3::Infra::NullExternalTaskActivityPublisher.new, external_follow_up_child_writer: nil)
      A3::Bootstrap::Session.build(
        manifest_path: manifest_path,
        preset_dir: preset_dir,
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
    end

    def runtime_package_descriptor(manifest_path:, preset_dir:, storage_backend:, storage_dir:, repo_sources: {}, image_version: ENV.fetch("A2O_IMAGE_VERSION", ENV.fetch("A3_IMAGE_VERSION", "dev")))
      A3::Domain::RuntimePackageDescriptor.build(
        image_version: image_version,
        manifest_path: manifest_path,
        preset_dir: preset_dir,
        storage_backend: storage_backend,
        storage_dir: storage_dir,
        repo_sources: repo_sources,
        manifest_schema_version: manifest_schema_version(manifest_path),
        required_manifest_schema_version: required_manifest_schema_version,
        preset_chain: preset_chain(manifest_path),
        preset_schema_versions: preset_schema_versions(manifest_path, preset_dir),
        required_preset_schema_version: required_preset_schema_version,
        secret_delivery_mode: ENV.fetch("A3_SECRET_DELIVERY_MODE", "environment_variable"),
        secret_reference: ENV.fetch("A3_SECRET_REFERENCE", "A3_SECRET"),
        scheduler_store_migration_state: ENV.fetch("A3_SCHEDULER_STORE_MIGRATION", "not_required"),
        migration_entrypoint: ENV.fetch("A3_MIGRATION_ENTRYPOINT", "bin/a3 migrate-scheduler-store"),
        agent_runtime_profile: ENV.fetch("A3_AGENT_RUNTIME_PROFILE", "host-local"),
        agent_control_plane_url: ENV.fetch("A3_AGENT_CONTROL_PLANE_URL", "http://127.0.0.1:7393"),
        agent_profile_path: ENV.fetch("A3_AGENT_PROFILE_PATH", "<agent-runtime-profile.json>")
      )
    end

    def runtime_package_session(manifest_path:, preset_dir:, storage_backend:, storage_dir:, repo_sources: {})
      A3::Bootstrap::RuntimePackageSession.build(
        runtime_package: runtime_package_descriptor(
          manifest_path: manifest_path,
          preset_dir: preset_dir,
          storage_backend: storage_backend,
          storage_dir: storage_dir,
          repo_sources: repo_sources
        )
      )
    end

    def runtime_environment_config(manifest_path:, preset_dir:, storage_backend:, storage_dir:, run_id_generator:, command_runner: A3::Infra::LocalCommandRunner.new, merge_runner: A3::Infra::DisabledMergeRunner.new, worker_gateway: nil, repo_sources: {})
      package_descriptor = runtime_package_descriptor(
        manifest_path: manifest_path,
        preset_dir: preset_dir,
        storage_backend: storage_backend,
        storage_dir: storage_dir,
        repo_sources: repo_sources
      )
      A3::Bootstrap::RuntimeEnvironmentConfig.build(
        runtime_package: package_descriptor,
        project_surface: project_surface(manifest_path: manifest_path, preset_dir: preset_dir),
        project_context: project_context(manifest_path: manifest_path, preset_dir: preset_dir),
        container: container(
          storage_backend: storage_backend,
          storage_dir: storage_dir,
          run_id_generator: run_id_generator,
          command_runner: command_runner,
          merge_runner: merge_runner,
          worker_gateway: worker_gateway,
          repo_sources: repo_sources
        )
      )
    end

    def doctor_runtime_environment_config(manifest_path:, preset_dir:, storage_backend:, storage_dir:, repo_sources: {})
      A3::Bootstrap::RuntimeEnvironmentConfig.runtime_only(
        runtime_package: runtime_package_descriptor(
          manifest_path: manifest_path,
          preset_dir: preset_dir,
          storage_backend: storage_backend,
          storage_dir: storage_dir,
          repo_sources: repo_sources
        )
      )
    end

    def manifest_session(manifest_path:, preset_dir:)
      A3::Bootstrap::ManifestSession.build(
        manifest_path: manifest_path,
        preset_dir: preset_dir
      )
    end

    def project_surface(manifest_path:, preset_dir:)
      A3::Adapters::ProjectSurfaceLoader.new(preset_dir: preset_dir).load(manifest_path)
    end

    def project_context(manifest_path:, preset_dir:)
      A3::Adapters::ProjectContextLoader.new(preset_dir: preset_dir).load(manifest_path)
    end

    def manifest_schema_version(manifest_path)
      path = Pathname(manifest_path)
      return "missing" unless path.file?

      document = manifest_document(manifest_path)
      schema_version = document.is_a?(Hash) ? document["schema_version"] : nil
      schema_version.to_s.empty? ? "missing" : schema_version.to_s
    end
    private_class_method :manifest_schema_version

    def preset_chain(manifest_path)
      document = manifest_document(manifest_path)
      runtime = document.is_a?(Hash) ? document["runtime"] : nil
      unless runtime.is_a?(Hash)
        raise A3::Domain::ConfigurationError, "project.yaml runtime must be provided"
      end
      return [] unless runtime.key?("presets")
      unless runtime["presets"].is_a?(Array)
        raise A3::Domain::ConfigurationError, "project.yaml runtime.presets must be an array"
      end

      runtime.fetch("presets").map(&:to_s).freeze
    end
    private_class_method :preset_chain

    def preset_schema_versions(manifest_path, preset_dir)
      preset_chain(manifest_path).each_with_object({}) do |preset_name, versions|
        preset_path = preset_file_path(preset_dir, preset_name)
        versions[preset_name] =
          if preset_path.file?
            document = YAML.safe_load(preset_path.read, permitted_classes: [], aliases: false)
            schema_version = document.is_a?(Hash) ? document["schema_version"] : nil
            schema_version.to_s.empty? ? "missing" : schema_version.to_s
          else
            "missing"
          end
      end.freeze
    end
    private_class_method :preset_schema_versions

    def preset_file_path(preset_dir, preset_name)
      yaml_path = Pathname(preset_dir).join("#{preset_name}.yaml")
      return yaml_path if yaml_path.file?

      Pathname(preset_dir).join("#{preset_name}.yml")
    end
    private_class_method :preset_file_path

    def required_manifest_schema_version
      ENV.fetch("A3_REQUIRED_MANIFEST_SCHEMA_VERSION", "1")
    end
    private_class_method :required_manifest_schema_version

    def required_preset_schema_version
      ENV.fetch("A3_REQUIRED_PRESET_SCHEMA_VERSION", "1")
    end
    private_class_method :required_preset_schema_version

    def manifest_document(manifest_path)
      if Pathname(manifest_path).basename.to_s == "manifest.yml"
        raise A3::Domain::ConfigurationError, "manifest.yml is no longer supported; use project.yaml"
      end
      YAML.safe_load(Pathname(manifest_path).read, permitted_classes: [], aliases: false)
    end
    private_class_method :manifest_document
  end
end
