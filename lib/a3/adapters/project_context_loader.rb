# frozen_string_literal: true

require "yaml"

module A3
  module Adapters
    class ProjectContextLoader
      def initialize(preset_dir:)
        @preset_dir = preset_dir
      end

      def load(manifest_path)
        manifest = YAML.load_file(manifest_path)
        surface = A3::Adapters::ProjectSurfaceLoader.new(preset_dir: @preset_dir).load(manifest_path)
        core = manifest.fetch("core") do
          raise A3::Domain::ConfigurationError, "manifest core.merge_target and core.merge_policy must be provided"
        end
        merge_target = core.fetch("merge_target") do
          raise A3::Domain::ConfigurationError, "manifest core.merge_target must be provided"
        end
        merge_policy = core.fetch("merge_policy") do
          raise A3::Domain::ConfigurationError, "manifest core.merge_policy must be provided"
        end
        merge_target_ref = core.fetch("merge_target_ref") do
          raise A3::Domain::ConfigurationError, "manifest core.merge_target_ref must be provided"
        end
        raise A3::Domain::ConfigurationError, "manifest core.merge_target_ref must not be blank" if String(merge_target_ref).strip.empty?

        merge_config_resolver = A3::Domain::MergeConfigResolver.new(
          target_spec: merge_target,
          policy_spec: merge_policy,
          target_ref_spec: merge_target_ref
        )

        A3::Domain::ProjectContext.new(
          surface: surface,
          merge_config: merge_config_resolver.default_merge_config,
          merge_config_resolver: merge_config_resolver
        )
      end
    end
  end
end
