# frozen_string_literal: true

module A3
  module Domain
    class OperatorInspectionReadModel
      class RunView
        class RuntimeSnapshot
          attr_reader :task_kind, :repo_scope, :phase, :implementation_skill, :review_skill,
                      :verification_commands, :remediation_commands, :workspace_hook, :merge_target, :merge_policy

          def initialize(task_kind:, repo_scope:, phase:, implementation_skill:, review_skill:,
                         verification_commands:, remediation_commands:, workspace_hook:, merge_target:, merge_policy:)
            @task_kind = task_kind.to_sym
            @repo_scope = repo_scope.to_sym
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
              phase: runtime_snapshot.phase,
              implementation_skill: runtime_snapshot.implementation_skill,
              review_skill: runtime_snapshot.review_skill,
              verification_commands: runtime_snapshot.verification_commands,
              remediation_commands: runtime_snapshot.remediation_commands,
              workspace_hook: runtime_snapshot.workspace_hook,
              merge_target: runtime_snapshot.merge_target,
              merge_policy: runtime_snapshot.merge_policy
            )
          end
        end
      end
    end
  end
end
