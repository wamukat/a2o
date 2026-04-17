# frozen_string_literal: true

require "yaml"

module A3
  module Adapters
    class ProjectContextLoader
      def initialize(preset_dir:)
        @preset_dir = preset_dir
      end

      def load(manifest_path)
        project_config = load_project_config(manifest_path)
        surface = A3::Adapters::ProjectSurfaceLoader.new(preset_dir: @preset_dir).load(manifest_path)
        runtime = project_config.fetch("runtime") do
          raise A3::Domain::ConfigurationError, "project.yaml runtime must be provided"
        end
        merge = runtime.fetch("merge") do
          raise A3::Domain::ConfigurationError, "project.yaml runtime.merge.target and runtime.merge.policy must be provided"
        end
        merge_target = merge.fetch("target") do
          raise A3::Domain::ConfigurationError, "project.yaml runtime.merge.target must be provided"
        end
        merge_policy = merge.fetch("policy") do
          raise A3::Domain::ConfigurationError, "project.yaml runtime.merge.policy must be provided"
        end
        merge_target_ref = merge.fetch("target_ref") do
          raise A3::Domain::ConfigurationError, "project.yaml runtime.merge.target_ref must be provided"
        end
        raise A3::Domain::ConfigurationError, "project.yaml runtime.merge.target_ref must not be blank" if String(merge_target_ref).strip.empty?

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

      private

      def load_project_config(path)
        if File.basename(path) == "manifest.yml"
          raise A3::Domain::ConfigurationError, "manifest.yml is no longer supported; use project.yaml"
        end
        payload = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
        unless payload.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml must contain a mapping"
        end
        schema_version = payload["schema_version"].to_s
        if schema_version.empty?
          raise A3::Domain::ConfigurationError, "project.yaml schema_version must be provided"
        end
        unless schema_version == "1"
          raise A3::Domain::ConfigurationError, "project.yaml schema_version is unsupported: #{schema_version}"
        end

        payload
      end
    end
  end
end
