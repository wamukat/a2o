# frozen_string_literal: true

require "a3/domain/branch_namespace"
require "a3/domain/delivery_config"

module A3
  module Domain
    class MergePlanningPolicy
      def initialize(branch_namespace: A3::Domain::BranchNamespace.from_env)
        @branch_namespace = BranchNamespace.normalize(branch_namespace)
      end

      def build(task:, run:, merge_config:, delivery_config: A3::Domain::DeliveryConfig.local_merge)
        MergePlan.new(
          project_key: run.project_key || task.project_key,
          task_ref: task.ref,
          run_ref: run.ref,
          merge_source: MergeSource.new(source_ref: run.source_descriptor.ref),
          integration_target: IntegrationTarget.new(
            target_ref: resolve_target_ref(task, merge_config, delivery_config),
            bootstrap_ref: resolve_bootstrap_ref(task, merge_config, delivery_config)
          ),
          merge_policy: merge_config.policy,
          merge_slots: task.edit_scope,
          delivery_config: delivery_config
        )
      end

      private

      def resolve_target_ref(task, merge_config, delivery_config)
        case merge_config.target
        when :merge_to_parent
          raise ConfigurationError, "merge_to_parent requires parent_ref" unless task.parent_ref

          parent_integration_ref(task.parent_ref)
        when :merge_to_live
          raise ConfigurationError, "merge_to_live requires parent task" unless task.kind == :parent || task.kind == :single

          raise ConfigurationError, "merge_to_live requires explicit target_ref" unless present?(merge_config.target_ref)

          return remote_branch_target_ref(task, delivery_config) if delivery_config.remote_branch?

          merge_config.target_ref
        else
          raise ConfigurationError, "Unsupported merge target: #{merge_config.target}"
        end
      end

      def resolve_bootstrap_ref(task, merge_config, delivery_config)
        case merge_config.target
        when :merge_to_parent
          raise ConfigurationError, "merge_to_parent requires parent_ref" unless task.parent_ref

          raise ConfigurationError, "merge_to_parent requires explicit bootstrap target_ref" unless present?(merge_config.target_ref)

          merge_config.target_ref
        when :merge_to_live
          return remote_branch_bootstrap_ref(delivery_config) if delivery_config.remote_branch?

          nil
        else
          raise ConfigurationError, "Unsupported merge target: #{merge_config.target}"
        end
      end

      def present?(value)
        !value.nil? && !value.to_s.strip.empty?
      end

      def parent_integration_ref(parent_ref)
        parts = ["refs/heads/a2o"]
        parts << @branch_namespace if @branch_namespace
        parts << "parent"
        parts << parent_ref.tr("#", "-")
        parts.join("/")
      end

      def remote_branch_target_ref(task, delivery_config)
        "refs/heads/#{delivery_config.branch_prefix}#{safe_task_ref(task.ref)}"
      end

      def remote_branch_bootstrap_ref(delivery_config)
        "refs/remotes/#{delivery_config.remote}/#{delivery_config.base_branch}"
      end

      def safe_task_ref(task_ref)
        normalized = task_ref.to_s.strip.gsub(%r{[^A-Za-z0-9._/-]+}, "-")
        normalized = normalized.gsub(%r{/+}, "/").gsub(%r{\A/+|/+\z}, "")
        normalized = normalized.gsub("..", ".")
        normalized.empty? ? "task" : normalized
      end

    end
  end
end
