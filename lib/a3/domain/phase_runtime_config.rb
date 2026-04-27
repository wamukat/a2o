# frozen_string_literal: true

module A3
  module Domain
    class PhaseRuntimeConfig
      attr_reader :task_kind, :repo_scope, :phase, :implementation_skill, :review_skill,
                  :verification_commands, :remediation_commands, :metrics_collection_commands, :workspace_hook, :merge_target, :merge_policy,
                  :merge_target_ref, :review_gate_required

      def initialize(task_kind:, repo_scope:, phase:, implementation_skill:, review_skill:, verification_commands:,
                     remediation_commands:, workspace_hook:, merge_target:, merge_policy:, metrics_collection_commands: [], merge_target_ref: nil,
                     review_gate_required: false)
        @task_kind = task_kind.to_sym
        @repo_scope = repo_scope.to_sym
        @phase = phase.to_sym
        @implementation_skill = implementation_skill
        @review_skill = review_skill
        @verification_commands = Array(verification_commands).freeze
        @remediation_commands = Array(remediation_commands).freeze
        @metrics_collection_commands = Array(metrics_collection_commands).freeze
        @workspace_hook = workspace_hook
        @merge_target = merge_target.to_sym
        @merge_policy = merge_policy.to_sym
        @merge_target_ref = merge_target_ref
        @review_gate_required = !!review_gate_required
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
          other.workspace_hook == workspace_hook &&
          other.merge_target == merge_target &&
          other.merge_policy == merge_policy &&
          other.merge_target_ref == merge_target_ref &&
          other.review_gate_required == review_gate_required
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
          "merge_target" => merge_target.to_s,
          "merge_policy" => merge_policy.to_s,
          "merge_target_ref" => merge_target_ref,
          "review_gate_required" => review_gate_required
        }
      end
    end
  end
end
