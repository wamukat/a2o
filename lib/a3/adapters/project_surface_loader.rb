# frozen_string_literal: true

require "yaml"

module A3
  module Adapters
    class ProjectSurfaceLoader
      def initialize(preset_dir:, required_preset_schema_version: ENV.fetch("A3_REQUIRED_PRESET_SCHEMA_VERSION", "1"))
        @preset_dir = preset_dir
        @required_preset_schema_version = required_preset_schema_version.to_s
      end

      def load(manifest_path)
        project_config = load_project_config(manifest_path)
        runtime = project_config.fetch("runtime") do
          raise A3::Domain::ConfigurationError, "project.yaml runtime must be provided"
        end
        presets = runtime.fetch("presets", [])
        unless presets.is_a?(Array)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.presets must be an array"
        end
        preset_payload = presets.reduce({}) do |merged, preset_name|
          merge_preset(merged, load_preset(preset_name))
        end
        project_payload = runtime.fetch("surface", {})
        payload = preset_payload.merge(project_payload)

        A3::Domain::ProjectSurface.new(
          implementation_skill: payload["implementation_skill"],
          review_skill: payload["review_skill"],
          verification_commands: payload.fetch("verification_commands", []),
          remediation_commands: payload.fetch("remediation_commands", []),
          workspace_hook: payload["workspace_hook"]
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

      def load_preset(name)
        payload = YAML.safe_load(File.read(preset_path(name)), permitted_classes: [], aliases: false)
        schema_version = payload["schema_version"].to_s
        if schema_version.empty? || schema_version != @required_preset_schema_version
          raise A3::Domain::ConfigurationError, "preset #{name} schema_version must be #{@required_preset_schema_version}"
        end

        payload.reject { |key, _| key == "schema_version" }
      end

      def preset_path(name)
        yaml_path = File.join(@preset_dir, "#{name}.yaml")
        return yaml_path if File.file?(yaml_path)

        File.join(@preset_dir, "#{name}.yml")
      end

      def merge_preset(merged, incoming)
        incoming.each_with_object(merged.dup) do |(key, value), acc|
          next acc[key] = value unless acc.key?(key)
          next if acc[key] == value
          if acc[key].is_a?(Hash) && value.is_a?(Hash)
            acc[key] = deep_merge_hash(acc[key], value, path: [key])
            next
          end

          raise A3::Domain::ConfigurationConflictError, "Conflicting preset values for #{key}"
        end
      end

      def deep_merge_hash(base, incoming, path:)
        incoming.each_with_object(base.dup) do |(key, value), acc|
          current_path = path + [key]
          next acc[key] = value unless acc.key?(key)
          next if acc[key] == value
          if acc[key].is_a?(Hash) && value.is_a?(Hash)
            acc[key] = deep_merge_hash(acc[key], value, path: current_path)
            next
          end

          raise A3::Domain::ConfigurationConflictError, "Conflicting preset values for #{current_path.join('.')}"
        end
      end
    end
  end
end
