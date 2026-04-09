# frozen_string_literal: true

module A3
  module Domain
    class MergePlanningPolicy
      def build(task:, run:, merge_config:)
        MergePlan.new(
          task_ref: task.ref,
          run_ref: run.ref,
          merge_source: MergeSource.new(source_ref: run.source_descriptor.ref),
          integration_target: IntegrationTarget.new(
            target_ref: resolve_target_ref(task, merge_config),
            bootstrap_ref: resolve_bootstrap_ref(task, merge_config)
          ),
          merge_policy: merge_config.policy,
          merge_slots: task.edit_scope
        )
      end

      private

      def resolve_target_ref(task, merge_config)
        case merge_config.target
        when :merge_to_parent
          raise ConfigurationError, "merge_to_parent requires parent_ref" unless task.parent_ref

          "refs/heads/a3/parent/#{task.parent_ref.tr('#', '-')}"
        when :merge_to_live
          raise ConfigurationError, "merge_to_live requires parent task" unless task.kind == :parent || task.kind == :single

          raise ConfigurationError, "merge_to_live requires explicit target_ref" unless present?(merge_config.target_ref)

          merge_config.target_ref
        else
          raise ConfigurationError, "Unsupported merge target: #{merge_config.target}"
        end
      end

      def resolve_bootstrap_ref(task, merge_config)
        case merge_config.target
        when :merge_to_parent
          raise ConfigurationError, "merge_to_parent requires parent_ref" unless task.parent_ref

          raise ConfigurationError, "merge_to_parent requires explicit bootstrap target_ref" unless present?(merge_config.target_ref)

          merge_config.target_ref
        when :merge_to_live
          nil
        else
          raise ConfigurationError, "Unsupported merge target: #{merge_config.target}"
        end
      end

      def present?(value)
        !value.nil? && !value.to_s.strip.empty?
      end
    end
  end
end
