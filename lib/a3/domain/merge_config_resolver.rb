# frozen_string_literal: true

module A3
  module Domain
    class MergeConfigResolver
      def initialize(policy_spec:, target_ref_spec: nil)
        @policy_spec = deep_freeze(policy_spec)
        raise ConfigurationError, "merge target ref must be provided" if target_ref_spec.nil?

        @target_ref_spec = deep_freeze(target_ref_spec)
        @default_merge_config = A3::Domain::MergeConfig.new(
          target: merge_target_for(:single),
          policy: resolve_variant(@policy_spec, task_kind: :single, repo_scope: :both, phase: :merge),
          target_ref: resolve_variant(@target_ref_spec, task_kind: :single, repo_scope: :both, phase: :merge)
        )
        freeze
      end

      attr_reader :default_merge_config

      def resolve(task:, phase:)
        A3::Domain::MergeConfig.new(
          target: merge_target_for(task.kind),
          policy: resolve_variant(@policy_spec, task_kind: task.kind, repo_scope: task.repo_scope_key, phase: phase),
          target_ref: resolve_variant(@target_ref_spec, task_kind: task.kind, repo_scope: task.repo_scope_key, phase: phase)
        )
      end

      private

      def merge_target_for(task_kind)
        task_kind.to_sym == :child ? :merge_to_parent : :merge_to_live
      end

      def resolve_variant(spec, task_kind:, repo_scope:, phase:)
        return normalize_variant_value(spec) unless spec.is_a?(Hash)

        default = spec.fetch("default")
        variants = spec.fetch("variants", {})
        task_variant = variants.fetch("task_kind", {}).fetch(task_kind.to_s, nil)
        return normalize_variant_value(default) unless task_variant

        repo_variant = task_variant.fetch("repo_scope", {}).fetch(repo_scope.to_s, nil)
        if repo_variant
          return normalize_variant_value(repo_variant.fetch("phase", {}).fetch(phase.to_s, repo_variant.fetch("default", default)))
        end

        normalize_variant_value(task_variant.fetch("phase", {}).fetch(phase.to_s, task_variant.fetch("default", default)))
      end

      def normalize_variant_value(value)
        return value.to_sym if value.is_a?(Symbol)

        string = String(value).strip
        raise ConfigurationError, "merge target ref must not be blank" if string.empty?

        return string.to_sym if string.start_with?("merge_to_")

        string
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested_value), frozen_hash|
            frozen_hash[key] = deep_freeze(nested_value)
          end.freeze
        when Array
          value.map { |element| deep_freeze(element) }.freeze
        else
          value.frozen? ? value : value.freeze
        end
      end
    end
  end
end
