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
        if runtime.key?("live_ref")
          raise A3::Domain::ConfigurationError, "project.yaml runtime.live_ref is no longer supported; use runtime.phases.merge.target_ref"
        end
        phases = runtime.fetch("phases") do
          raise A3::Domain::ConfigurationError, "project.yaml runtime.phases must be provided"
        end
        unless phases.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.phases must be a mapping"
        end
        reject_legacy_workspace_hook(phases)
        payload = surface_payload_from_phases(phases)

        A3::Domain::ProjectSurface.new(
          implementation_skill: payload["implementation_skill"],
          review_skill: payload["review_skill"],
          verification_commands: payload.fetch("verification_commands", []),
          remediation_commands: payload.fetch("remediation_commands", []),
          metrics_collection_commands: payload.fetch("metrics_collection_commands", []),
          notification_config: A3::Domain::NotificationConfig.from_project_config(runtime.fetch("notifications", nil)),
          workspace_hook: nil,
          decomposition_investigate_command: decomposition_command(runtime, "investigate"),
          decomposition_author_command: decomposition_command(runtime, "author"),
          decomposition_review_commands: decomposition_review_commands(runtime),
          prompt_config: prompt_config(runtime)
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
        metrics = optional_phase_mapping(phases, "metrics")

        payload = {
          "implementation_skill" => implementation.fetch("skill") do
            raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.implementation.skill must be provided"
          end,
          "review_skill" => review.fetch("skill") do
            raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.review.skill must be provided"
          end,
          "verification_commands" => verification.fetch("commands", []),
          "remediation_commands" => remediation.fetch("commands", []),
          "metrics_collection_commands" => metrics.fetch("commands", [])
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

      def reject_legacy_workspace_hook(phases)
        phases.each do |name, phase|
          next unless phase.is_a?(Hash) && phase.key?("workspace_hook")

          raise A3::Domain::ConfigurationError,
                "project.yaml runtime.phases.#{name}.workspace_hook is no longer supported; use phase commands or project package commands"
        end
      end

      def prompt_config(runtime)
        prompts = runtime.fetch("prompts", nil)
        return A3::Domain::ProjectPromptConfig.empty unless prompts
        unless prompts.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.prompts must be a mapping"
        end

        A3::Domain::ProjectPromptConfig.new(
          system_file: system_prompt_file(prompts),
          phases: prompt_phase_mapping(prompts.fetch("phases", {}), "runtime.prompts.phases"),
          repo_slots: prompt_repo_slots(prompts.fetch("repoSlots", {}))
        )
      end

      def system_prompt_file(prompts)
        system = prompts.fetch("system", nil)
        return nil unless system
        unless system.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.prompts.system must be a mapping"
        end

        prompt_path(system.fetch("file", nil), "runtime.prompts.system.file", required: true)
      end

      def prompt_repo_slots(repo_slots)
        unless repo_slots.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.prompts.repoSlots must be a mapping"
        end

        repo_slots.each_with_object({}) do |(slot, config), mapping|
          unless slot.is_a?(String) && !slot.strip.empty?
            raise A3::Domain::ConfigurationError, "project.yaml runtime.prompts.repoSlots keys must be non-empty strings"
          end
          unless config.is_a?(Hash)
            raise A3::Domain::ConfigurationError, "project.yaml runtime.prompts.repoSlots.#{slot} must be a mapping"
          end
          mapping[slot] = prompt_phase_mapping(
            config.fetch("phases", {}),
            "runtime.prompts.repoSlots.#{slot}.phases"
          )
        end
      end

      def prompt_phase_mapping(phases, location)
        unless phases.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must be a mapping"
        end

        phases.each_with_object({}) do |(phase, config), mapping|
          unless phase.is_a?(String) && !phase.strip.empty?
            raise A3::Domain::ConfigurationError, "project.yaml #{location} keys must be non-empty strings"
          end
          unless config.is_a?(Hash)
            raise A3::Domain::ConfigurationError, "project.yaml #{location}.#{phase} must be a mapping"
          end

          mapping[phase] = A3::Domain::ProjectPromptConfig::PhaseConfig.new(
            prompt_file: prompt_path(config.fetch("prompt", nil), "#{location}.#{phase}.prompt"),
            skill_files: prompt_skill_files(config.fetch("skills", []), "#{location}.#{phase}.skills"),
            child_draft_template_file: prompt_path(config.fetch("childDraftTemplate", nil), "#{location}.#{phase}.childDraftTemplate")
          )
        end
      end

      def prompt_path(value, location, required: false)
        if value.nil?
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must be a non-empty string" if required

          return nil
        end
        unless value.is_a?(String) && !value.strip.empty?
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must be a non-empty string"
        end

        value
      end

      def prompt_skill_files(value, location)
        unless value.is_a?(Array)
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must be an array of non-empty strings"
        end
        value.each_with_index do |entry, index|
          unless entry.is_a?(String) && !entry.strip.empty?
            raise A3::Domain::ConfigurationError, "project.yaml #{location}[#{index}] must be a non-empty string"
          end
        end

        value
      end

      def decomposition_command(runtime, name)
        decomposition = runtime.fetch("decomposition", nil)
        return nil unless decomposition
        unless decomposition.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.decomposition must be a mapping"
        end

        step = decomposition.fetch(name, nil)
        return nil unless step
        unless step.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.decomposition.#{name} must be a mapping"
        end

        command = step.fetch("command") do
          raise A3::Domain::ConfigurationError, "project.yaml runtime.decomposition.#{name}.command must be provided"
        end
        unless command.is_a?(Array) && command.any? && command.all? { |entry| entry.is_a?(String) && !entry.empty? }
          raise A3::Domain::ConfigurationError,
                "project.yaml runtime.decomposition.#{name}.command must be a non-empty array of non-empty strings"
        end

        command
      end

      def decomposition_review_commands(runtime)
        decomposition = runtime.fetch("decomposition", nil)
        return [] unless decomposition
        unless decomposition.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.decomposition must be a mapping"
        end

        review = decomposition.fetch("review", nil)
        return [] unless review
        unless review.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.decomposition.review must be a mapping"
        end

        commands = review.fetch("commands") do
          raise A3::Domain::ConfigurationError, "project.yaml runtime.decomposition.review.commands must be provided"
        end
        unless commands.is_a?(Array) && commands.any?
          raise A3::Domain::ConfigurationError,
                "project.yaml runtime.decomposition.review.commands must be a non-empty array of command arrays"
        end
        commands.each do |command|
          unless command.is_a?(Array) && command.any? && command.all? { |entry| entry.is_a?(String) && !entry.empty? }
            raise A3::Domain::ConfigurationError,
                  "project.yaml runtime.decomposition.review.commands must be a non-empty array of command arrays"
          end
        end
        commands
      end
    end
  end
end
