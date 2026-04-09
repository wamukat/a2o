# frozen_string_literal: true

module A3
  module CLI
    module HandlerSupport
      WORKER_GATEWAY_UNSET = Object.new
      ManifestSession = Struct.new(:options, :project_surface, :project_context, keyword_init: true)
      StorageSession = Struct.new(:options, :container, keyword_init: true)
      StorageRuntimePackageSession = Struct.new(:options, :container, :runtime_package, keyword_init: true)
      RuntimePackageSession = Struct.new(:options, :runtime_package, keyword_init: true)
      RuntimeSession = Struct.new(:options, :container, :project_context, :project_surface, :runtime_package, :runtime_environment_config, keyword_init: true)

      def with_storage_container(argv:, parse_with:, run_id_generator:, command_runner:, merge_runner:, worker_gateway: WORKER_GATEWAY_UNSET)
        options = public_send(parse_with, argv)
        container_kwargs = {
          options: options,
          run_id_generator: run_id_generator,
          command_runner: command_runner,
          merge_runner: merge_runner
        }
        container_kwargs[:worker_gateway] = worker_gateway unless worker_gateway.equal?(WORKER_GATEWAY_UNSET)
        container = build_storage_container(**container_kwargs)
        yield options, container
      end

      def with_storage_session(argv:, parse_with:, run_id_generator:, command_runner:, merge_runner:, worker_gateway: WORKER_GATEWAY_UNSET)
        options = public_send(parse_with, argv)
        yield build_storage_session(
          options: options,
          run_id_generator: run_id_generator,
          command_runner: command_runner,
          merge_runner: merge_runner,
          worker_gateway: worker_gateway
        )
      end

      def with_manifest_session(argv:, parse_with:)
        options = public_send(parse_with, argv)
        yield build_manifest_session(
          options: options
        )
      end

      def with_runtime_session(argv:, parse_with:, run_id_generator:, command_runner:, merge_runner:, worker_gateway: WORKER_GATEWAY_UNSET)
        options = public_send(parse_with, argv)
        yield build_runtime_session(
          options: options,
          run_id_generator: run_id_generator,
          command_runner: command_runner,
          merge_runner: merge_runner,
          worker_gateway: worker_gateway
        )
      end

      def with_runtime_package_session(argv:, parse_with:)
        options = public_send(parse_with, argv)
        yield build_runtime_package_session(options: options)
      end

      def with_storage_runtime_package_session(argv:, parse_with:, run_id_generator:, command_runner:, merge_runner:, worker_gateway: WORKER_GATEWAY_UNSET)
        options = public_send(parse_with, argv)
        yield StorageRuntimePackageSession.new(
          options: options,
          container: build_storage_container(
            options: options,
            run_id_generator: run_id_generator,
            command_runner: command_runner,
            merge_runner: merge_runner,
            worker_gateway: worker_gateway
          ),
          runtime_package: build_runtime_package_session(options: options).runtime_package
        )
      end

      private

      def build_manifest_session(options:)
        session = A3::Bootstrap.manifest_session(
          manifest_path: options.fetch(:manifest_path),
          preset_dir: options.fetch(:preset_dir)
        )
        ManifestSession.new(
          options: options,
          project_surface: session.project_surface,
          project_context: session.project_context
        )
      end

      def build_storage_session(options:, run_id_generator:, command_runner:, merge_runner:, worker_gateway:)
        StorageSession.new(
          options: options,
          container: build_storage_container(
            options: options,
            run_id_generator: run_id_generator,
            command_runner: command_runner,
            merge_runner: merge_runner,
            worker_gateway: worker_gateway
          )
        )
      end

      def build_runtime_session(options:, run_id_generator:, command_runner:, merge_runner:, worker_gateway:)
        session_kwargs = {
          options: options,
          run_id_generator: run_id_generator,
          command_runner: command_runner,
          merge_runner: merge_runner
        }
        session_kwargs[:worker_gateway] = worker_gateway unless worker_gateway.equal?(WORKER_GATEWAY_UNSET)
        session = build_bootstrap_session(**session_kwargs)
        RuntimeSession.new(
          options: options,
          container: session.container,
          project_context: session.project_context,
          project_surface: session.project_surface,
          runtime_package: session.runtime_package,
          runtime_environment_config: session.runtime_environment_config
        )
      end

      def build_runtime_package_session(options:)
        session = A3::Bootstrap.runtime_package_session(
          manifest_path: options.fetch(:manifest_path),
          preset_dir: options.fetch(:preset_dir),
          storage_backend: options.fetch(:storage_backend),
          storage_dir: options.fetch(:storage_dir),
          repo_sources: options.fetch(:repo_sources, {})
        )
        RuntimePackageSession.new(
          options: options,
          runtime_package: session.runtime_package
        )
      end
    end
  end
end
