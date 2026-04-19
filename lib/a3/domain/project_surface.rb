# frozen_string_literal: true

module A3
  module Domain
    class ProjectSurface
      SURFACE_KEYS = %i[
        implementation_skill
        review_skill
        verification_commands
        remediation_commands
        workspace_hook
      ].freeze

      attr_reader(*SURFACE_KEYS)

      def initialize(implementation_skill:, review_skill:, verification_commands:, remediation_commands:, workspace_hook:)
        @implementation_skill = deep_freeze_value(implementation_skill)
        @review_skill = deep_freeze_value(review_skill)
        @verification_commands = deep_freeze_value(verification_commands)
        @remediation_commands = deep_freeze_value(remediation_commands)
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
        return default unless repo_variant

        repo_variant.fetch("phase", {}).fetch(phase.to_s, default)
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
