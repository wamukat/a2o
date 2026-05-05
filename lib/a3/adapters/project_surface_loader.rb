# frozen_string_literal: true

require "yaml"
require "pathname"

module A3
  module Adapters
    class ProjectSurfaceLoader
      PROMPT_PHASES = %w[
        implementation
        implementation_rework
        review
        parent_review
        verification
        remediation
        metrics
        decomposition
      ].freeze

      def initialize(preset_dir:, required_preset_schema_version: ENV.fetch("A3_REQUIRED_PRESET_SCHEMA_VERSION", "1"))
        # Kept for CLI call-site compatibility while project.yaml phases replace presets.
      end

      def load(manifest_path)
        project_config = load_project_config(manifest_path)
        project_package_root = File.dirname(File.expand_path(manifest_path))
        validate_docs_config(project_config.fetch("docs", nil), project_package_root, project_config.fetch("repos", {}))
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
        project_prompt_config = prompt_config(runtime, project_package_root, repo_slots: repo_slot_names(project_config))
        payload = surface_payload_from_phases(phases, prompt_config: project_prompt_config)

        A3::Domain::ProjectSurface.new(
          implementation_skill: payload["implementation_skill"],
          implementation_completion_hooks: payload.fetch("implementation_completion_hooks", []),
          review_skill: payload["review_skill"],
          verification_commands: payload.fetch("verification_commands", []),
          remediation_commands: payload.fetch("remediation_commands", []),
          metrics_collection_commands: payload.fetch("metrics_collection_commands", []),
          notification_config: A3::Domain::NotificationConfig.from_project_config(runtime.fetch("notifications", nil)),
          workspace_hook: nil,
          decomposition_investigate_command: decomposition_command(runtime, "investigate"),
          decomposition_author_command: decomposition_command(runtime, "author"),
          decomposition_review_commands: decomposition_review_commands(runtime),
          prompt_config: project_prompt_config,
          scheduler_config: A3::Domain::ProjectSchedulerConfig.from_project_config(runtime.fetch("scheduler", nil)),
          docs_config: project_config.fetch("docs", nil)
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

      def surface_payload_from_phases(phases, prompt_config:)
        implementation = phase_mapping(phases, "implementation")
        review = phase_mapping(phases, "review")
        verification = optional_phase_mapping(phases, "verification")
        remediation = optional_phase_mapping(phases, "remediation")
        metrics = optional_phase_mapping(phases, "metrics")

        payload = {
          "implementation_skill" => phase_skill_or_prompt_backed_nil(implementation, "implementation", prompt_config),
          "implementation_completion_hooks" => implementation_completion_hooks(implementation),
          "review_skill" => phase_skill_or_prompt_backed_nil(review, "review", prompt_config),
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

      def phase_skill_or_prompt_backed_nil(phase, name, prompt_config)
        return phase.fetch("skill") if phase.key?("skill")
        return nil if prompt_phase_configured?(prompt_config, name)

        raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.#{name}.skill must be provided"
      end

      def implementation_completion_hooks(implementation)
        completion_hooks = implementation.fetch("completion_hooks", nil)
        return [] if completion_hooks.nil?
        unless completion_hooks.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.implementation.completion_hooks must be a mapping"
        end
        commands = completion_hooks.fetch("commands", [])
        unless commands.is_a?(Array)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.implementation.completion_hooks.commands must be a sequence"
        end
        commands.each_with_index.map do |hook, index|
          unless hook.is_a?(Hash)
            raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.implementation.completion_hooks.commands[#{index}] must be a mapping"
          end
          unsupported = hook.keys.map(&:to_s) - %w[name command mode on_failure]
          unless unsupported.empty?
            raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.implementation.completion_hooks.commands[#{index}].#{unsupported.first} is not supported"
          end
          {
            "name" => required_completion_hook_string(hook, "name", index),
            "command" => required_completion_hook_string(hook, "command", index),
            "mode" => required_completion_hook_mode(hook, index),
            "on_failure" => completion_hook_on_failure(hook, index)
          }
        end
      end

      def required_completion_hook_string(hook, key, index)
        unless hook.key?(key)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.implementation.completion_hooks.commands[#{index}].#{key} must be provided"
        end
        value = hook.fetch(key)
        unless value.is_a?(String) && !value.strip.empty?
          raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.implementation.completion_hooks.commands[#{index}].#{key} must be a non-empty string"
        end

        value.strip
      end

      def required_completion_hook_mode(hook, index)
        mode = required_completion_hook_string(hook, "mode", index)
        unless %w[mutating check].include?(mode)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.implementation.completion_hooks.commands[#{index}].mode must be mutating or check"
        end

        mode
      end

      def completion_hook_on_failure(hook, index)
        on_failure = hook.fetch("on_failure", "rework").to_s.strip
        on_failure = "rework" if on_failure.empty?
        unless on_failure == "rework"
          raise A3::Domain::ConfigurationError, "project.yaml runtime.phases.implementation.completion_hooks.commands[#{index}].on_failure must be rework"
        end

        on_failure
      end

      def prompt_phase_configured?(prompt_config, name)
        return false unless prompt_config

        !prompt_config.phase(name).empty?
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

      def repo_slot_names(project_config)
        repos = project_config.fetch("repos", {})
        return [] unless repos.is_a?(Hash)

        repos.keys.map(&:to_s)
      end

      def validate_docs_config(docs, project_package_root, repos)
        return unless docs
        unless docs.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml docs must be a mapping"
        end

        repo_slot = docs.fetch("repoSlot", nil)
        if docs.key?("repoSlot") && (!repo_slot.is_a?(String) || repo_slot.strip.empty?)
          raise A3::Domain::ConfigurationError, "project.yaml docs.repoSlot must be a non-empty string"
        end
        repo_slot = nil if repo_slot.to_s.strip.empty?
        repo_names = repos.is_a?(Hash) ? repos.keys.map(&:to_s).sort : []
        surfaces = docs.fetch("surfaces", nil)
        if surfaces
          validate_docs_surfaces(surfaces, docs, project_package_root, repos, repo_names)
          validate_docs_languages(docs.fetch("languages", nil))
          validate_docs_mapping(docs.fetch("policy", nil), "docs.policy")
          validate_docs_mapping(docs.fetch("impactPolicy", nil), "docs.impactPolicy")
          validate_docs_authorities(docs.fetch("authorities", nil), project_package_root, repos, docs, surfaces)
          return
        end
        if repo_slot && !repo_names.empty? && !repo_names.include?(repo_slot)
          raise A3::Domain::ConfigurationError, "project.yaml docs.repoSlot must match a repos entry: #{repo_slot}"
        end
        if !repo_slot && repo_names.length > 1
          raise A3::Domain::ConfigurationError, "project.yaml docs.repoSlot must be provided when multiple repos are declared"
        end
        repo_slot ||= repo_names.first
        repo_root = docs_repo_root(project_package_root, repos, repo_slot)

        validate_docs_path(docs.fetch("root", nil), "docs.root", repo_root, required: true)
        validate_docs_path(docs.fetch("index", nil), "docs.index", repo_root)
        validate_docs_categories(docs.fetch("categories", nil), repo_root)
        validate_docs_languages(docs.fetch("languages", nil))
        validate_docs_mapping(docs.fetch("policy", nil), "docs.policy")
        validate_docs_mapping(docs.fetch("impactPolicy", nil), "docs.impactPolicy")
        validate_docs_authorities(docs.fetch("authorities", nil), project_package_root, repos, docs, nil)
      end

      def validate_docs_surfaces(surfaces, docs, project_package_root, repos, repo_names)
        unless surfaces.is_a?(Hash) && !surfaces.empty?
          raise A3::Domain::ConfigurationError, "project.yaml docs.surfaces must be a non-empty mapping"
        end
        surfaces.each do |id, surface|
          unless machine_key?(id)
            raise A3::Domain::ConfigurationError, "project.yaml docs.surfaces.#{id} id must be a non-empty machine-readable key"
          end
          unless surface.is_a?(Hash)
            raise A3::Domain::ConfigurationError, "project.yaml docs.surfaces.#{id} must be a mapping"
          end
          surface_slot = docs_repo_slot(surface.fetch("repoSlot", nil), repo_names, "docs.surfaces.#{id}.repoSlot")
          surface_slot ||= docs_repo_slot(docs.fetch("repoSlot", nil), repo_names, "docs.repoSlot")
          surface_slot ||= repo_names.first if repo_names.length == 1
          if surface_slot.nil? && repo_names.length > 1
            raise A3::Domain::ConfigurationError, "project.yaml docs.surfaces.#{id}.repoSlot must be provided when multiple repos are declared"
          end
          repo_root = docs_repo_root(project_package_root, repos, surface_slot)
          validate_docs_path(surface.fetch("root", nil), "docs.surfaces.#{id}.root", repo_root, required: true)
          validate_docs_path(surface.fetch("index", nil), "docs.surfaces.#{id}.index", repo_root)
          validate_docs_categories(surface.fetch("categories", nil), repo_root, "docs.surfaces.#{id}.categories")
          validate_docs_languages(surface.fetch("languages", docs.fetch("languages", nil)))
          validate_docs_mapping(surface.fetch("policy", docs.fetch("policy", nil)), "docs.surfaces.#{id}.policy")
          validate_docs_mapping(surface.fetch("impactPolicy", docs.fetch("impactPolicy", nil)), "docs.surfaces.#{id}.impactPolicy")
        end
      end

      def docs_repo_slot(raw_slot, repo_names, location)
        return nil if raw_slot.nil?
        unless raw_slot.is_a?(String) && !raw_slot.strip.empty?
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must be a non-empty string"
        end
        slot = raw_slot.strip
        if !repo_names.empty? && !repo_names.include?(slot)
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must match a repos entry: #{slot}"
        end
        slot
      end

      def docs_repo_root(project_package_root, repos, repo_slot)
        return nil unless repos.is_a?(Hash) && repo_slot

        repo = repos.fetch(repo_slot, nil)
        return nil unless repo.is_a?(Hash)

        path = repo.fetch("path", nil)
        return nil unless path.is_a?(String) && !path.strip.empty?

        Pathname.new(path).absolute? ? File.expand_path(path) : File.expand_path(path, project_package_root)
      end

      def validate_docs_categories(categories, repo_root, location = "docs.categories")
        return unless categories
        unless categories.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must be a mapping"
        end

        categories.each do |id, category|
          unless machine_key?(id)
            raise A3::Domain::ConfigurationError, "project.yaml #{location}.#{id} id must be a non-empty machine-readable key"
          end
          unless category.is_a?(Hash)
            raise A3::Domain::ConfigurationError, "project.yaml #{location}.#{id} must be a mapping"
          end
          validate_docs_path(category.fetch("path", nil), "#{location}.#{id}.path", repo_root, required: true)
          validate_docs_path(category.fetch("index", nil), "#{location}.#{id}.index", repo_root)
        end
      end

      def validate_docs_authorities(authorities, project_package_root, repos, docs, surfaces)
        return unless authorities
        unless authorities.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml docs.authorities must be a mapping"
        end

        authorities.each do |id, authority|
          unless machine_key?(id)
            raise A3::Domain::ConfigurationError, "project.yaml docs.authorities.#{id} id must be a non-empty machine-readable key"
          end
          unless authority.is_a?(Hash)
            raise A3::Domain::ConfigurationError, "project.yaml docs.authorities.#{id} must be a mapping"
          end
          repo_names = repos.is_a?(Hash) ? repos.keys.map(&:to_s).sort : []
          repo_slot = docs_repo_slot(authority.fetch("repoSlot", nil), repo_names, "docs.authorities.#{id}.repoSlot")
          repo_slot ||= docs_repo_slot(docs.fetch("repoSlot", nil), repo_names, "docs.repoSlot")
          repo_slot ||= repo_names.first if repo_names.length == 1
          if repo_slot.nil? && surfaces && repo_names.length > 1
            raise A3::Domain::ConfigurationError, "project.yaml docs.authorities.#{id}.repoSlot must be provided when docs.surfaces and multiple repos are declared"
          end
          repo_root = docs_repo_root(project_package_root, repos, repo_slot)
          generated = authority.fetch("generated", false) == true
          validate_docs_path(authority.fetch("source", nil), "docs.authorities.#{id}.source", repo_root, required: !generated)
          source = authority.fetch("source", nil)
          if !generated && repo_root && source.is_a?(String) && !source.strip.empty?
            source_path = File.expand_path(source, repo_root)
            unless File.exist?(source_path)
              raise A3::Domain::ConfigurationError, "project.yaml docs.authorities.#{id}.source file not found: #{source}"
            end
          end
          docs_paths = authority.fetch("docs", nil)
          case docs_paths
          when nil
            next
          when String
            validate_docs_path(docs_paths, "docs.authorities.#{id}.docs", repo_root)
          when Array
            docs_paths.each_with_index do |entry, index|
              if entry.is_a?(Hash)
                surface_id = entry.fetch("surface", nil)
                unless surface_id.is_a?(String) && !surface_id.strip.empty?
                  raise A3::Domain::ConfigurationError, "project.yaml docs.authorities.#{id}.docs[#{index}].surface must be a non-empty string"
                end
                surface_root = docs_surface_repo_root(project_package_root, repos, docs, surfaces, surface_id.strip)
                validate_docs_path(entry.fetch("path", nil), "docs.authorities.#{id}.docs[#{index}].path", surface_root, required: true)
                next
              end
              validate_docs_path(entry, "docs.authorities.#{id}.docs[#{index}]", repo_root, required: true)
            end
          else
            raise A3::Domain::ConfigurationError, "project.yaml docs.authorities.#{id}.docs must be a string or array of strings/maps"
          end
        end
      end

      def docs_surface_repo_root(project_package_root, repos, docs, surfaces, surface_id)
        unless surfaces.is_a?(Hash) && surfaces.key?(surface_id)
          raise A3::Domain::ConfigurationError, "project.yaml docs surface not found: #{surface_id}"
        end
        surface = surfaces.fetch(surface_id)
        unless surface.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml docs.surfaces.#{surface_id} must be a mapping"
        end
        repo_names = repos.is_a?(Hash) ? repos.keys.map(&:to_s).sort : []
        repo_slot = docs_repo_slot(surface.fetch("repoSlot", nil), repo_names, "docs.surfaces.#{surface_id}.repoSlot")
        repo_slot ||= docs_repo_slot(docs.fetch("repoSlot", nil), repo_names, "docs.repoSlot")
        repo_slot ||= repo_names.first if repo_names.length == 1
        if repo_slot.nil? && repo_names.length > 1
          raise A3::Domain::ConfigurationError, "project.yaml docs.surfaces.#{surface_id}.repoSlot must be provided when multiple repos are declared"
        end
        docs_repo_root(project_package_root, repos, repo_slot)
      end

      def validate_docs_languages(languages)
        return unless languages
        unless languages.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml docs.languages must be a mapping"
        end
        if languages.key?("primary") && (!languages["primary"].is_a?(String) || languages["primary"].strip.empty?)
          raise A3::Domain::ConfigurationError, "project.yaml docs.languages.primary must be a non-empty string"
        end
        %w[secondary required].each do |key|
          next unless languages.key?(key)

          list = languages.fetch(key)
          unless list.is_a?(Array)
            raise A3::Domain::ConfigurationError, "project.yaml docs.languages.#{key} must be an array of non-empty strings"
          end
          list.each_with_index do |entry, index|
            unless entry.is_a?(String) && !entry.strip.empty?
              raise A3::Domain::ConfigurationError, "project.yaml docs.languages.#{key}[#{index}] must be a non-empty string"
            end
          end
        end
      end

      def validate_docs_mapping(mapping, location)
        return unless mapping
        unless mapping.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must be a mapping"
        end
        if mapping.keys.any? { |key| key.to_s.strip.empty? }
          raise A3::Domain::ConfigurationError, "project.yaml #{location} keys must be non-empty strings"
        end
      end

      def validate_docs_path(value, location, repo_root, required: false)
        if value.nil?
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must be a non-empty repo-slot-relative path" if required

          return
        end
        unless value.is_a?(String) && !value.strip.empty?
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must be a non-empty repo-slot-relative path"
        end
        if Pathname.new(value).absolute?
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must be relative to the docs repo slot"
        end
        if value.split(/[\\\/]/).include?("..")
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must stay inside the docs repo slot"
        end
        return unless repo_root

        root = File.expand_path(repo_root)
        absolute_path = File.expand_path(value, root)
        unless absolute_path == root || absolute_path.start_with?("#{root}#{File::SEPARATOR}")
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must stay inside the docs repo slot"
        end
        return unless File.exist?(root)

        real_root = File.realpath(root)
        real_path = File.realpath(nearest_existing_path(absolute_path))
        unless real_path == real_root || real_path.start_with?("#{real_root}#{File::SEPARATOR}")
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must stay inside the docs repo slot"
        end
      end

      def nearest_existing_path(path)
        current = path
        until File.exist?(current) || File.symlink?(current)
          parent = File.dirname(current)
          raise Errno::ENOENT, path if parent == current

          current = parent
        end
        current
      end

      def machine_key?(value)
        value.is_a?(String) && value.match?(/\A[a-z][a-z0-9_]*\z/)
      end

      def prompt_config(runtime, project_package_root, repo_slots:)
        prompts = runtime.fetch("prompts", nil)
        return A3::Domain::ProjectPromptConfig.empty unless prompts
        unless prompts.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.prompts must be a mapping"
        end
        phases = prompt_phase_mapping(prompts.fetch("phases", {}), "runtime.prompts.phases", project_package_root)

        A3::Domain::ProjectPromptConfig.new(
          system_document: system_prompt_document(prompts, project_package_root),
          phases: phases,
          repo_slots: prompt_repo_slots(prompts.fetch("repoSlots", {}), project_package_root, known_slots: repo_slots, base_phases: phases)
        )
      end

      def system_prompt_document(prompts, project_package_root)
        system = prompts.fetch("system", nil)
        return nil unless system
        unless system.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.prompts.system must be a mapping"
        end

        prompt_document(system.fetch("file", nil), "runtime.prompts.system.file", project_package_root, required: true)
      end

      def prompt_repo_slots(repo_slots, project_package_root, known_slots:, base_phases:)
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
          if !known_slots.empty? && !known_slots.include?(slot)
            raise A3::Domain::ConfigurationError, "project.yaml runtime.prompts.repoSlots.#{slot} must match a repos entry"
          end
          slot_phases = prompt_phase_mapping(
            config.fetch("phases", {}),
            "runtime.prompts.repoSlots.#{slot}.phases",
            project_package_root
          )
          validate_repo_slot_skill_addons(slot, base_phases, slot_phases)
          mapping[slot] = slot_phases
        end
      end

      def prompt_phase_mapping(phases, location, project_package_root)
        unless phases.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must be a mapping"
        end

        phases.each_with_object({}) do |(phase, config), mapping|
          unless phase.is_a?(String) && !phase.strip.empty?
            raise A3::Domain::ConfigurationError, "project.yaml #{location} keys must be non-empty strings"
          end
          unless PROMPT_PHASES.include?(phase)
            raise A3::Domain::ConfigurationError, "project.yaml #{location}.#{phase} is not a supported prompt phase"
          end
          unless config.is_a?(Hash)
            raise A3::Domain::ConfigurationError, "project.yaml #{location}.#{phase} must be a mapping"
          end
          if config.key?("childDraftTemplate") && phase != "decomposition"
            raise A3::Domain::ConfigurationError, "project.yaml #{location}.#{phase}.childDraftTemplate is only supported for decomposition"
          end

          mapping[phase] = A3::Domain::ProjectPromptConfig::PhaseConfig.new(
            prompt_document: prompt_document(config.fetch("prompt", nil), "#{location}.#{phase}.prompt", project_package_root),
            skill_documents: prompt_skill_documents(config.fetch("skills", []), "#{location}.#{phase}.skills", project_package_root),
            child_draft_template_document: prompt_document(config.fetch("childDraftTemplate", nil), "#{location}.#{phase}.childDraftTemplate", project_package_root)
          )
        end
      end

      def prompt_document(value, location, project_package_root, required: false)
        if value.nil?
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must be a non-empty string" if required

          return nil
        end
        unless value.is_a?(String) && !value.strip.empty?
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must be a non-empty string"
        end

        load_prompt_document(value, location, project_package_root)
      end

      def prompt_skill_documents(value, location, project_package_root)
        unless value.is_a?(Array)
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must be an array of non-empty strings"
        end
        duplicates = value.select { |entry| value.count(entry) > 1 }.uniq
        unless duplicates.empty?
          raise A3::Domain::ConfigurationError, "project.yaml #{location} contains duplicate skill file: #{duplicates.first}"
        end
        value.each_with_index do |entry, index|
          unless entry.is_a?(String) && !entry.strip.empty?
            raise A3::Domain::ConfigurationError, "project.yaml #{location}[#{index}] must be a non-empty string"
          end
        end
        value.each_with_index.map do |entry, index|
          load_prompt_document(entry, "#{location}[#{index}]", project_package_root)
        end
      end

      def validate_repo_slot_skill_addons(slot, base_phases, slot_phases)
        slot_phases.each do |phase, slot_config|
          base_phase = base_phase_for_repo_slot_addon(phase, base_phases)
          base_config = base_phases.fetch(base_phase, A3::Domain::ProjectPromptConfig::PhaseConfig.new)
          duplicate = (base_config.skill_files & slot_config.skill_files).first
          next unless duplicate

          raise A3::Domain::ConfigurationError,
                "project.yaml runtime.prompts.repoSlots.#{slot}.phases.#{phase}.skills duplicates runtime.prompts.phases.#{base_phase}.skills entry: #{duplicate}"
        end
      end

      def base_phase_for_repo_slot_addon(phase, base_phases)
        phase_name = phase.to_s
        return phase_name unless phase_name == "implementation_rework"

        rework_config = base_phases.fetch("implementation_rework", A3::Domain::ProjectPromptConfig::PhaseConfig.new)
        implementation_config = base_phases.fetch("implementation", A3::Domain::ProjectPromptConfig::PhaseConfig.new)
        return "implementation" if rework_config.empty? && !implementation_config.empty?

        phase_name
      end

      def load_prompt_document(path, location, project_package_root)
        if Pathname.new(path).absolute?
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must be relative to the project package root"
        end
        root = File.expand_path(project_package_root)
        absolute_path = File.expand_path(path, root)
        unless absolute_path == root || absolute_path.start_with?("#{root}#{File::SEPARATOR}")
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must stay inside the project package root"
        end
        unless File.exist?(absolute_path)
          raise A3::Domain::ConfigurationError, "project.yaml #{location} file not found: #{path}"
        end
        real_root = File.realpath(root)
        real_path = File.realpath(absolute_path)
        unless real_path == real_root || real_path.start_with?("#{real_root}#{File::SEPARATOR}")
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must stay inside the project package root"
        end
        unless File.file?(absolute_path)
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must reference a file: #{path}"
        end
        content = File.read(absolute_path, mode: "r:UTF-8")
        unless content.valid_encoding?
          raise A3::Domain::ConfigurationError, "project.yaml #{location} must be UTF-8 text: #{path}"
        end

        A3::Domain::ProjectPromptConfig::Document.new(
          path: path,
          absolute_path: absolute_path,
          content: content
        )
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
