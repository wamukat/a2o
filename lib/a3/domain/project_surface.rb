# frozen_string_literal: true

require "a3/domain/project_scheduler_config"

module A3
  module Domain
    class ProjectSurface
      SURFACE_KEYS = %i[
        implementation_skill
        implementation_completion_hooks
        review_skill
        verification_commands
        remediation_commands
        metrics_collection_commands
        observer_config
        decomposition_investigate_command
        decomposition_author_command
        decomposition_review_commands
        prompt_config
        scheduler_config
        docs_config
        workspace_hook
      ].freeze

      attr_reader(*SURFACE_KEYS)

      def initialize(implementation_skill:, review_skill:, verification_commands:, remediation_commands:, workspace_hook:, implementation_completion_hooks: [], metrics_collection_commands: [], observer_config: A3::Domain::ObserverConfig.empty, decomposition_investigate_command: nil, decomposition_author_command: nil, decomposition_review_commands: [], prompt_config: A3::Domain::ProjectPromptConfig.empty, scheduler_config: A3::Domain::ProjectSchedulerConfig.default, docs_config: nil)
        @implementation_skill = deep_freeze_value(implementation_skill)
        @implementation_completion_hooks = deep_freeze_value(implementation_completion_hooks)
        @review_skill = deep_freeze_value(review_skill)
        @verification_commands = deep_freeze_value(verification_commands)
        @remediation_commands = deep_freeze_value(remediation_commands)
        @metrics_collection_commands = deep_freeze_value(metrics_collection_commands)
        @observer_config = observer_config || A3::Domain::ObserverConfig.empty
        @decomposition_investigate_command = deep_freeze_value(decomposition_investigate_command)
        @decomposition_author_command = deep_freeze_value(decomposition_author_command)
        @decomposition_review_commands = deep_freeze_value(decomposition_review_commands)
        @prompt_config = prompt_config || A3::Domain::ProjectPromptConfig.empty
        @scheduler_config = scheduler_config || A3::Domain::ProjectSchedulerConfig.default
        @docs_config = deep_freeze_value(docs_config)
        @workspace_hook = deep_freeze_value(workspace_hook)
        freeze
      end

      def resolve(key, task_kind:, repo_scope:, phase:)
        value = public_send(key)
        return value unless value.is_a?(Hash)

        default = value.fetch("default")
        variants = value.fetch("variants", {})
        task_variant = variants.fetch("task_kind", {}).fetch(task_kind.to_s, nil)
        return default unless task_variant

        repo_variant = task_variant.fetch("repo_scope", {}).fetch(repo_scope.to_s, nil)
        if repo_variant
          return repo_variant.fetch("phase", {}).fetch(phase.to_s, repo_variant.fetch("default", default))
        end

        task_variant.fetch("phase", {}).fetch(phase.to_s, task_variant.fetch("default", default))
      end

      private

      def deep_freeze_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested_value), frozen_hash|
            frozen_hash[key] = deep_freeze_value(nested_value)
          end.freeze
        when Array
          value.map { |element| deep_freeze_value(element) }.freeze
        else
          value.frozen? ? value : value.freeze
        end
      end
    end
  end
end
