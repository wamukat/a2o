# frozen_string_literal: true

require "set"

module A3
  module Domain
    class ProjectContext
      attr_reader :surface, :merge_config, :delivery_config, :review_gate

      def initialize(surface:, merge_config:, merge_config_resolver: nil, delivery_config: A3::Domain::DeliveryConfig.local_merge, review_gate: {})
        @surface = surface
        @merge_config = merge_config
        @merge_config_resolver = merge_config_resolver
        @delivery_config = delivery_config || A3::Domain::DeliveryConfig.local_merge
        @review_gate = normalize_review_gate(review_gate)
        freeze
      end

      def resolve_phase_runtime(task:, phase:)
        resolved_merge_config = merge_config_for(task: task, phase: phase)
        A3::Domain::PhaseRuntimeConfig.new(
          task_kind: task.kind,
          repo_scope: task.repo_scope_key,
          repo_slots: task.repo_slots,
          phase: phase,
          implementation_skill: surface.resolve(:implementation_skill, task_kind: task.kind, repo_scope: task.repo_scope_key, phase: phase),
          review_skill: surface.resolve(:review_skill, task_kind: task.kind, repo_scope: task.repo_scope_key, phase: phase),
          verification_commands: Array(surface.resolve(:verification_commands, task_kind: task.kind, repo_scope: task.repo_scope_key, phase: phase)),
          remediation_commands: Array(surface.resolve(:remediation_commands, task_kind: task.kind, repo_scope: task.repo_scope_key, phase: phase)),
          metrics_collection_commands: Array(surface.resolve(:metrics_collection_commands, task_kind: task.kind, repo_scope: task.repo_scope_key, phase: phase)),
          observer_config: surface.observer_config,
          workspace_hook: surface.workspace_hook,
          merge_target: resolved_merge_config.target,
          merge_policy: resolved_merge_config.policy,
          merge_target_ref: resolved_merge_config.target_ref,
          review_gate_required: review_gate_required?(task.kind, labels: task.labels),
          project_prompt_config: surface.prompt_config,
          docs_config: surface.docs_config
        )
      end

      def review_gate_required?(task_kind, labels: [])
        task_labels = Array(labels).map(&:to_s).to_set
        required = !!review_gate.fetch(:required_by_kind).fetch(task_kind.to_sym, false)
        required = true if review_gate.fetch(:require_labels).any? { |label| task_labels.include?(label) }
        required = false if review_gate.fetch(:skip_labels).any? { |label| task_labels.include?(label) }
        required
      end

      def merge_config_for(task:, phase:)
        return merge_config unless @merge_config_resolver

        @merge_config_resolver.resolve(task: task, phase: phase)
      end

      private

      def normalize_review_gate(value)
        mapping = value || {}
        {
          required_by_kind: {
            child: !!mapping.fetch(:child, mapping.fetch("child", false)),
            single: !!mapping.fetch(:single, mapping.fetch("single", false))
          }.freeze,
          skip_labels: normalize_label_list(mapping.fetch(:skip_labels, mapping.fetch("skip_labels", []))),
          require_labels: normalize_label_list(mapping.fetch(:require_labels, mapping.fetch("require_labels", [])))
        }.freeze
      end

      def normalize_label_list(value)
        Array(value).map(&:to_s).map(&:strip).reject(&:empty?).uniq.freeze
      end
    end
  end
end
