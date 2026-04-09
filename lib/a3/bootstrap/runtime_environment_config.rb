# frozen_string_literal: true

module A3
  module Bootstrap
    class RuntimeEnvironmentConfig
      attr_reader :runtime_package, :project_surface, :project_context, :container

      def self.build(runtime_package:, project_surface:, project_context:, container:)
        new(
          runtime_package: runtime_package,
          project_surface: project_surface,
          project_context: project_context,
          container: container
        )
      end

      def self.runtime_only(runtime_package:)
        new(
          runtime_package: runtime_package,
          project_surface: nil,
          project_context: nil,
          container: nil
        )
      end

      def initialize(runtime_package:, project_surface:, project_context:, container:)
        @runtime_package = runtime_package
        @project_surface = project_surface
        @project_context = project_context
        @container = container
        freeze
      end

      def manifest_path
        runtime_package.manifest_path
      end

      def preset_dir
        runtime_package.preset_dir
      end

      def storage_backend
        runtime_package.storage_backend
      end

      def storage_dir
        runtime_package.storage_dir
      end

      def repo_sources
        runtime_package.repo_sources
      end

      def writable_roots
        runtime_package.writable_roots
      end

      def mount_summary
        runtime_package.mount_summary
      end

      def repo_source_summary
        runtime_package.repo_source_summary
      end

      def operator_summary
        runtime_package.operator_summary
      end

      def validate!
        raise A3::Domain::ConfigurationError, "runtime_package must be present" unless runtime_package
        raise A3::Domain::ConfigurationError, "project_surface must be present" unless project_surface
        raise A3::Domain::ConfigurationError, "project_context must be present" unless project_context
        raise A3::Domain::ConfigurationError, "container must be present" unless container

        self
      end

      def healthy?
        validate!
        true
      rescue A3::Domain::ConfigurationError
        false
      end
    end
  end
end
