# frozen_string_literal: true

module A3
  module Domain
    class PhaseRuntimeSnapshot
      attr_reader :task_kind, :repo_scope, :repo_slots, :phase, :implementation_skill, :review_skill,
                  :verification_commands, :remediation_commands, :metrics_collection_commands, :observer_config, :workspace_hook, :merge_target, :merge_policy,
                  :review_gate_required

      def initialize(task_kind:, repo_scope:, phase:, implementation_skill:, review_skill:,
                     verification_commands:, remediation_commands:, workspace_hook:, merge_target:, merge_policy:, metrics_collection_commands: [],
                     observer_config: A3::Domain::ObserverConfig.empty, review_gate_required: false, repo_slots: nil)
        @task_kind = task_kind.to_sym
        @repo_scope = repo_scope.to_sym
        @repo_slots = normalize_repo_slots(repo_slots, fallback_scope: @repo_scope)
        @phase = phase.to_sym
        @implementation_skill = implementation_skill
        @review_skill = review_skill
        @verification_commands = Array(verification_commands).freeze
        @remediation_commands = Array(remediation_commands).freeze
        @metrics_collection_commands = Array(metrics_collection_commands).freeze
        @observer_config = observer_config || A3::Domain::ObserverConfig.empty
        @workspace_hook = workspace_hook
        @merge_target = merge_target.to_sym
        @merge_policy = merge_policy.to_sym
        @review_gate_required = !!review_gate_required
        freeze
      end

      def self.from_phase_runtime(runtime)
        new(
          task_kind: runtime.task_kind,
          repo_scope: runtime.repo_scope,
          repo_slots: runtime.repo_slots,
          phase: runtime.phase,
          implementation_skill: runtime.implementation_skill,
          review_skill: runtime.review_skill,
          verification_commands: runtime.verification_commands,
          remediation_commands: runtime.remediation_commands,
          metrics_collection_commands: runtime.metrics_collection_commands,
          observer_config: runtime.observer_config,
          workspace_hook: runtime.workspace_hook,
          merge_target: runtime.merge_target,
          merge_policy: runtime.merge_policy,
          review_gate_required: runtime.review_gate_required
        )
      end

      def self.from_persisted_form(record)
        return nil unless record

        new(
          task_kind: record.fetch("task_kind"),
          repo_scope: record.fetch("repo_scope"),
          repo_slots: record.fetch("repo_slots", nil),
          phase: record.fetch("phase"),
          implementation_skill: record["implementation_skill"],
          review_skill: record["review_skill"],
          verification_commands: record.fetch("verification_commands", []),
          remediation_commands: record.fetch("remediation_commands", []),
          metrics_collection_commands: record.fetch("metrics_collection_commands", []),
          observer_config: A3::Domain::ObserverConfig.from_persisted_form(record["observers"]),
          workspace_hook: record["workspace_hook"],
          merge_target: record.fetch("merge_target"),
          merge_policy: record.fetch("merge_policy"),
          review_gate_required: record.fetch("review_gate_required", false)
        )
      end

      def persisted_form
        {
          "task_kind" => task_kind.to_s,
          "repo_scope" => repo_scope.to_s,
          "repo_slots" => repo_slots.map(&:to_s),
          "phase" => phase.to_s,
          "implementation_skill" => implementation_skill,
          "review_skill" => review_skill,
          "verification_commands" => verification_commands,
          "remediation_commands" => remediation_commands,
          "metrics_collection_commands" => metrics_collection_commands,
          "observers" => observer_config.persisted_form,
          "workspace_hook" => workspace_hook,
          "merge_target" => merge_target.to_s,
          "merge_policy" => merge_policy.to_s,
          "review_gate_required" => review_gate_required
        }
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.task_kind == task_kind &&
          other.repo_scope == repo_scope &&
          other.repo_slots == repo_slots &&
          other.phase == phase &&
          other.implementation_skill == implementation_skill &&
          other.review_skill == review_skill &&
          other.verification_commands == verification_commands &&
          other.remediation_commands == remediation_commands &&
          other.metrics_collection_commands == metrics_collection_commands &&
          other.observer_config == observer_config &&
          other.workspace_hook == workspace_hook &&
          other.merge_target == merge_target &&
          other.merge_policy == merge_policy &&
          other.review_gate_required == review_gate_required
      end
      alias eql? ==

      private

      def normalize_repo_slots(value, fallback_scope:)
        slots = Array(value).map(&:to_sym).reject { |slot| slot.to_s.empty? }.uniq
        slots = [fallback_scope] if slots.empty? && fallback_scope != :both
        slots.freeze
      end
    end
  end
end
