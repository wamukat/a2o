# frozen_string_literal: true

require_relative "../../task_phase_projection"

module A3
  module Domain
    class OperatorInspectionReadModel
      class RunView
        class RuntimeSnapshot
          attr_reader :task_kind, :repo_scope, :repo_slots, :phase, :implementation_skill, :review_skill,
                      :verification_commands, :remediation_commands, :workspace_hook, :merge_target, :merge_policy

          def initialize(task_kind:, repo_scope:, phase:, implementation_skill:, review_skill:,
                         repo_slots: nil,
                         verification_commands:, remediation_commands:, workspace_hook:, merge_target:, merge_policy:)
            @task_kind = task_kind.to_sym
            @repo_scope = repo_scope.to_sym
            @repo_slots = normalize_repo_slots(repo_slots, fallback_scope: @repo_scope)
            @phase = phase.to_sym
            @implementation_skill = implementation_skill
            @review_skill = review_skill
            @verification_commands = Array(verification_commands).freeze
            @remediation_commands = Array(remediation_commands).freeze
            @workspace_hook = workspace_hook
            @merge_target = merge_target.to_sym
            @merge_policy = merge_policy.to_sym
            freeze
          end

          def self.from_phase_runtime_snapshot(runtime_snapshot)
            return nil unless runtime_snapshot

            new(
              task_kind: runtime_snapshot.task_kind,
              repo_scope: runtime_snapshot.repo_scope,
              repo_slots: runtime_snapshot.repo_slots,
              phase: A3::Domain::TaskPhaseProjection.phase_for(task_kind: runtime_snapshot.task_kind, phase: runtime_snapshot.phase),
              implementation_skill: runtime_snapshot.implementation_skill,
              review_skill: runtime_snapshot.review_skill,
              verification_commands: runtime_snapshot.verification_commands,
              remediation_commands: runtime_snapshot.remediation_commands,
              workspace_hook: runtime_snapshot.workspace_hook,
              merge_target: runtime_snapshot.merge_target,
              merge_policy: runtime_snapshot.merge_policy
            )
          end

          def normalize_repo_slots(value, fallback_scope:)
            slots = Array(value).map(&:to_sym).reject { |slot| slot.to_s.empty? }.uniq
            slots = [fallback_scope] if slots.empty? && fallback_scope != :both
            slots.freeze
          end
        end
      end
    end
  end
end
