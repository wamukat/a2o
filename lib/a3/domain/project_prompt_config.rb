# frozen_string_literal: true

module A3
  module Domain
    class ProjectPromptConfig
      class Document
        attr_reader :path, :absolute_path, :content

        def initialize(path:, absolute_path:, content:)
          @path = path.freeze
          @absolute_path = absolute_path.freeze
          @content = content.freeze
          freeze
        end
      end

      class PhaseConfig
        attr_reader :prompt_file, :prompt_files, :prompt_document, :prompt_documents,
                    :skill_files, :skill_documents, :child_draft_template_file,
                    :child_draft_template_document

        def initialize(prompt_file: nil, prompt_files: nil, prompt_document: nil, prompt_documents: nil, skill_files: nil, skill_documents: [], child_draft_template_file: nil, child_draft_template_document: nil)
          prompt_file ||= prompt_document&.path
          ordered_prompt_documents = prompt_documents || Array(prompt_document).compact
          ordered_prompt_files = prompt_files || ordered_prompt_documents.map(&:path)
          skill_files ||= skill_documents.map(&:path)
          child_draft_template_file ||= child_draft_template_document&.path
          @prompt_file = prompt_file&.freeze
          @prompt_files = ordered_prompt_files.map(&:freeze).freeze
          @prompt_document = prompt_document
          @prompt_documents = ordered_prompt_documents.freeze
          @skill_files = skill_files.map(&:freeze).freeze
          @skill_documents = skill_documents.freeze
          @child_draft_template_file = child_draft_template_file&.freeze
          @child_draft_template_document = child_draft_template_document
          freeze
        end

        def empty?
          prompt_files.empty? && skill_files.empty? && child_draft_template_file.nil?
        end

        def persisted_form
          form = {}
          form["prompt"] = prompt_file if prompt_file
          form["skills"] = skill_files unless skill_files.empty?
          form["childDraftTemplate"] = child_draft_template_file if child_draft_template_file
          form.freeze
        end

        def merge_addon(addon)
          self.class.new(
            prompt_file: addon.prompt_file || prompt_file,
            prompt_files: prompt_files + addon.prompt_files,
            prompt_document: addon.prompt_document || prompt_document,
            prompt_documents: prompt_documents + addon.prompt_documents,
            skill_files: skill_files + addon.skill_files,
            skill_documents: skill_documents + addon.skill_documents,
            child_draft_template_file: addon.child_draft_template_file || child_draft_template_file,
            child_draft_template_document: addon.child_draft_template_document || child_draft_template_document
          )
        end
      end

      attr_reader :system_file, :system_document, :phases, :repo_slots

      def initialize(system_file: nil, system_document: nil, phases: {}, repo_slots: {})
        @system_document = system_document
        @system_file = (system_file || system_document&.path)&.freeze
        @phases = freeze_phase_mapping(phases)
        @repo_slots = repo_slots.each_with_object({}) do |(slot, slot_phases), frozen_slots|
          frozen_slots[slot.to_s.freeze] = freeze_phase_mapping(slot_phases)
        end.freeze
        freeze
      end

      def self.empty
        @empty ||= new
      end

      def empty?
        system_file.nil? && phases.empty? && repo_slots.empty?
      end

      def phase(name)
        phase_name = name.to_s
        config = phases.fetch(phase_name, nil)
        return config if config && !config.empty?

        return phase(:implementation) if phase_name == "implementation_rework"

        PhaseConfig.new
      end

      def repo_slot_phase(slot, phase)
        base_config = self.phase(phase)
        base_config.merge_addon(repo_slot_addon_phase(slot, phase))
      end

      def repo_slot_addon_phase(slot, phase)
        repo_slots.fetch(slot.to_s, {}).fetch(phase.to_s, PhaseConfig.new)
      end

      def persisted_form
        form = {}
        form["system"] = { "file" => system_file } if system_file
        form["phases"] = phases.transform_values(&:persisted_form) unless phases.empty?
        unless repo_slots.empty?
          form["repoSlots"] = repo_slots.transform_values do |slot_phases|
            { "phases" => slot_phases.transform_values(&:persisted_form) }
          end
        end
        form.freeze
      end

      private

      def freeze_phase_mapping(mapping)
        mapping.each_with_object({}) do |(phase, config), frozen_phases|
          frozen_phases[phase.to_s.freeze] = config
        end.freeze
      end
    end
  end
end
