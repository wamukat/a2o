# frozen_string_literal: true

module A3
  module Domain
    class PhaseRuntimeConfig
      attr_reader :task_kind, :repo_scope, :phase, :implementation_skill, :review_skill,
                  :verification_commands, :remediation_commands, :metrics_collection_commands, :notification_config, :workspace_hook, :merge_target, :merge_policy,
                  :merge_target_ref, :review_gate_required, :project_prompt_config, :docs_config

      def initialize(task_kind:, repo_scope:, phase:, implementation_skill:, review_skill:, verification_commands:,
                     remediation_commands:, workspace_hook:, merge_target:, merge_policy:, metrics_collection_commands: [], merge_target_ref: nil,
                     notification_config: A3::Domain::NotificationConfig.empty, review_gate_required: false, project_prompt_config: A3::Domain::ProjectPromptConfig.empty, docs_config: nil)
        @task_kind = task_kind.to_sym
        @repo_scope = repo_scope.to_sym
        @phase = phase.to_sym
        @implementation_skill = implementation_skill
        @review_skill = review_skill
        @verification_commands = Array(verification_commands).freeze
        @remediation_commands = Array(remediation_commands).freeze
        @metrics_collection_commands = Array(metrics_collection_commands).freeze
        @notification_config = notification_config || A3::Domain::NotificationConfig.empty
        @workspace_hook = workspace_hook
        @merge_target = merge_target.to_sym
        @merge_policy = merge_policy.to_sym
        @merge_target_ref = merge_target_ref
        @review_gate_required = !!review_gate_required
        @project_prompt_config = project_prompt_config || A3::Domain::ProjectPromptConfig.empty
        @docs_config = deep_freeze_value(docs_config)
        freeze
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.task_kind == task_kind &&
          other.repo_scope == repo_scope &&
          other.phase == phase &&
          other.implementation_skill == implementation_skill &&
          other.review_skill == review_skill &&
          other.verification_commands == verification_commands &&
          other.remediation_commands == remediation_commands &&
          other.metrics_collection_commands == metrics_collection_commands &&
          other.notification_config == notification_config &&
          other.workspace_hook == workspace_hook &&
          other.merge_target == merge_target &&
          other.merge_policy == merge_policy &&
          other.merge_target_ref == merge_target_ref &&
          other.review_gate_required == review_gate_required &&
          other.project_prompt_config == project_prompt_config &&
          other.docs_config == docs_config
      end
      alias eql? ==

      def worker_request_form
        {
          "task_kind" => task_kind.to_s,
          "repo_scope" => repo_scope.to_s,
          "phase" => phase.to_s,
          "workspace_hook" => workspace_hook,
          "implementation_skill" => implementation_skill,
          "review_skill" => review_skill,
          "verification_commands" => verification_commands,
          "remediation_commands" => remediation_commands,
          "metrics_collection_commands" => metrics_collection_commands,
          "notifications" => notification_config.persisted_form,
          "merge_target" => merge_target.to_s,
          "merge_policy" => merge_policy.to_s,
          "merge_target_ref" => merge_target_ref,
          "review_gate_required" => review_gate_required,
          "docs_configured" => !docs_config.nil?
        }
      end

      private

      def deep_freeze_value(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, entry), frozen| frozen[key] = deep_freeze_value(entry) }.freeze
        when Array
          value.map { |entry| deep_freeze_value(entry) }.freeze
        else
          value.frozen? ? value : value&.freeze
        end
      end
    end
  end
end
