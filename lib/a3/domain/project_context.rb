# frozen_string_literal: true

module A3
  module Domain
    class ProjectContext
      attr_reader :surface, :merge_config, :review_gate

      def initialize(surface:, merge_config:, merge_config_resolver: nil, review_gate: {})
        @surface = surface
        @merge_config = merge_config
        @merge_config_resolver = merge_config_resolver
        @review_gate = normalize_review_gate(review_gate)
        freeze
      end

      def resolve_phase_runtime(task:, phase:)
        resolved_merge_config = merge_config_for(task: task, phase: phase)
        A3::Domain::PhaseRuntimeConfig.new(
          task_kind: task.kind,
          repo_scope: task.repo_scope_key,
          phase: phase,
          implementation_skill: surface.resolve(:implementation_skill, task_kind: task.kind, repo_scope: task.repo_scope_key, phase: phase),
          review_skill: surface.resolve(:review_skill, task_kind: task.kind, repo_scope: task.repo_scope_key, phase: phase),
          verification_commands: Array(surface.resolve(:verification_commands, task_kind: task.kind, repo_scope: task.repo_scope_key, phase: phase)),
          remediation_commands: Array(surface.resolve(:remediation_commands, task_kind: task.kind, repo_scope: task.repo_scope_key, phase: phase)),
          workspace_hook: surface.workspace_hook,
          merge_target: resolved_merge_config.target,
          merge_policy: resolved_merge_config.policy,
          merge_target_ref: resolved_merge_config.target_ref,
          review_gate_required: review_gate_required?(task.kind)
        )
      end

      def review_gate_required?(task_kind)
        !!review_gate[task_kind.to_sym]
      end

      def merge_config_for(task:, phase:)
        return merge_config unless @merge_config_resolver

        @merge_config_resolver.resolve(task: task, phase: phase)
      end

      private

      def normalize_review_gate(value)
        mapping = value || {}
        {
          child: !!mapping.fetch(:child, mapping.fetch("child", false)),
          single: !!mapping.fetch(:single, mapping.fetch("single", false))
        }.freeze
      end
    end
  end
end
