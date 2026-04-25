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
        if runtime.key?("executor")
          raise A3::Domain::ConfigurationError, "project.yaml runtime.executor is no longer supported; use runtime.phases.<phase>.executor"
        end
        if runtime.key?("surface")
          raise A3::Domain::ConfigurationError, "project.yaml runtime.surface is no longer supported; use runtime.phases"
        end
        if runtime.key?("merge")
          raise A3::Domain::ConfigurationError, "project.yaml runtime.merge is no longer supported; use runtime.phases.merge"
        end
        if runtime.key?("live_ref")
          raise A3::Domain::ConfigurationError, "project.yaml runtime.live_ref is no longer supported; use runtime.phases.merge.target_ref"
        end
        phases = runtime.fetch("phases") do
          raise A3::Domain::ConfigurationError, "project.yaml runtime.phases must be provided"
        end
        unless phases.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.phases must be a mapping"
        end
        merge = phases.fetch("merge") do
          raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.merge.policy and runtime.phases.merge.target_ref must be provided"
        end
        unless merge.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.merge must be a mapping"
        end
        if merge.key?("target")
          raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.merge.target is no longer supported; A2O derives merge target from task topology"
        end
        merge_policy = merge.fetch("policy") do
          raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.merge.policy must be provided"
        end
        merge_target_ref = merge.fetch("target_ref") do
          raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.merge.target_ref must be provided"
        end
        raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.merge.target_ref must not be blank" if String(merge_target_ref).strip.empty?

        merge_config_resolver = A3::Domain::MergeConfigResolver.new(
          policy_spec: merge_policy,
          target_ref_spec: merge_target_ref
        )

        A3::Domain::ProjectContext.new(
          surface: surface,
          merge_config: merge_config_resolver.default_merge_config,
          merge_config_resolver: merge_config_resolver,
          review_gate: review_gate_config(runtime)
        )
      end

      private

      def review_gate_config(runtime)
        gate = runtime.fetch("review_gate", {})
        unless gate.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.review_gate must be a mapping"
        end
        {
          child: boolean_gate_value(gate.fetch("child", false), "child"),
          single: boolean_gate_value(gate.fetch("single", false), "single"),
          skip_labels: label_list_gate_value(gate.fetch("skip_labels", []), "skip_labels"),
          require_labels: label_list_gate_value(gate.fetch("require_labels", []), "require_labels")
        }
      end

      def boolean_gate_value(value, key)
        return value if value == true || value == false

        raise A3::Domain::ConfigurationError, "project.yaml runtime.review_gate.#{key} must be true or false"
      end

      def label_list_gate_value(value, key)
        unless value.is_a?(Array)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.review_gate.#{key} must be an array of strings"
        end

        value.map.with_index do |item, index|
          label = item.to_s.strip
          if label.empty? || !item.is_a?(String)
            raise A3::Domain::ConfigurationError, "project.yaml runtime.review_gate.#{key}[#{index}] must be a non-empty string"
          end
          label
        end.uniq.freeze
      end

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
