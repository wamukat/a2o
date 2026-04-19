# frozen_string_literal: true

require "yaml"

module A3
  module Adapters
    class ProjectSurfaceLoader
      def initialize(preset_dir:, required_preset_schema_version: ENV.fetch("A3_REQUIRED_PRESET_SCHEMA_VERSION", "1"))
        # Kept for CLI call-site compatibility while project.yaml phases replace presets.
      end

      def load(manifest_path)
        project_config = load_project_config(manifest_path)
        runtime = project_config.fetch("runtime") do
          raise A3::Domain::ConfigurationError, "project.yaml runtime must be provided"
        end
        if runtime.key?("presets")
          raise A3::Domain::ConfigurationError, "project.yaml runtime.presets is no longer supported; use runtime.phases"
        end
        if runtime.key?("surface")
          raise A3::Domain::ConfigurationError, "project.yaml runtime.surface is no longer supported; use runtime.phases"
        end
        if runtime.key?("executor")
          raise A3::Domain::ConfigurationError, "project.yaml runtime.executor is no longer supported; use runtime.phases.<phase>.executor"
        end
        if runtime.key?("merge")
          raise A3::Domain::ConfigurationError, "project.yaml runtime.merge is no longer supported; use runtime.phases.merge"
        end
        phases = runtime.fetch("phases") do
          raise A3::Domain::ConfigurationError, "project.yaml runtime.phases must be provided"
        end
        unless phases.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.phases must be a mapping"
        end
        payload = surface_payload_from_phases(phases)

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

      def surface_payload_from_phases(phases)
        implementation = phase_mapping(phases, "implementation")
        review = phase_mapping(phases, "review")
        verification = optional_phase_mapping(phases, "verification")
        remediation = optional_phase_mapping(phases, "remediation")

        payload = {
          "implementation_skill" => implementation.fetch("skill") do
            raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.implementation.skill must be provided"
          end,
          "review_skill" => review.fetch("skill") do
            raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.review.skill must be provided"
          end,
          "verification_commands" => verification.fetch("commands", []),
          "remediation_commands" => remediation.fetch("commands", []),
          "workspace_hook" => implementation["workspace_hook"]
        }
        parent_review = optional_phase_mapping(phases, "parent_review")
        if parent_review.key?("skill")
          payload["review_skill"] = {
            "default" => payload.fetch("review_skill"),
            "variants" => {
              "task_kind" => {
                "parent" => {
                  "repo_scope" => {
                    "both" => {
                      "phase" => {
                        "review" => parent_review.fetch("skill")
                      }
                    }
                  }
                }
              }
            }
          }
        end
        payload
      end

      def phase_mapping(phases, name)
        phase = phases.fetch(name) do
          raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.#{name} must be provided"
        end
        unless phase.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.#{name} must be a mapping"
        end
        phase
      end

      def optional_phase_mapping(phases, name)
        phase = phases.fetch(name, {})
        unless phase.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.#{name} must be a mapping"
        end
        phase
      end

    end
  end
end
