# frozen_string_literal: true

module A3
  module Bootstrap
    class ManifestSession
      attr_reader :manifest_path, :preset_dir, :project_surface, :project_context

      def self.build(manifest_path:, preset_dir:)
        project_surface = A3::Bootstrap.project_surface(
          manifest_path: manifest_path,
          preset_dir: preset_dir
        )

        new(
          manifest_path: manifest_path,
          preset_dir: preset_dir,
          project_surface: project_surface,
          project_context: A3::Bootstrap.project_context(
            manifest_path: manifest_path,
            preset_dir: preset_dir
          )
        )
      end

      def initialize(manifest_path:, preset_dir:, project_surface:, project_context:)
        @manifest_path = manifest_path
        @preset_dir = preset_dir
        @project_surface = project_surface
        @project_context = project_context
        freeze
      end
    end
  end
end
