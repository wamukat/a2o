# frozen_string_literal: true

module A3
  module Domain
    class WorkspacePolicy
      WORKSPACE_KIND_BY_PHASE = {
        implementation: :ticket_workspace,
        review: :runtime_workspace,
        verification: :runtime_workspace,
        merge: :runtime_workspace
      }.freeze

      def build_plan(phase:, source_descriptor:, scope_snapshot:)
        phase_name = phase.to_sym
        workspace_kind = workspace_kind_for(phase_name)
        validate_source_descriptor!(phase: phase_name, workspace_kind: workspace_kind, source_descriptor: source_descriptor)

        WorkspacePlan.new(
          workspace_kind: workspace_kind,
          source_descriptor: source_descriptor,
          slot_requirements: slot_requirements_for(scope_snapshot)
        )
      end

      def workspace_kind_for(phase)
        WORKSPACE_KIND_BY_PHASE.fetch(phase.to_sym)
      end

      def slot_requirements_for(scope_snapshot)
        eager_requirements = scope_snapshot.edit_scope.map do |repo_slot|
          SlotRequirement.new(repo_slot: repo_slot, sync_class: :eager)
        end

        lazy_requirements = (scope_snapshot.verification_scope - scope_snapshot.edit_scope).map do |repo_slot|
          SlotRequirement.new(repo_slot: repo_slot, sync_class: :lazy_but_guaranteed)
        end

        eager_requirements + lazy_requirements
      end

      def validate_source_descriptor!(phase:, workspace_kind:, source_descriptor:)
        return if source_descriptor.workspace_kind == workspace_kind

        raise ConfigurationError,
          "phase #{phase} requires #{workspace_kind} source descriptor, got #{source_descriptor.workspace_kind}"
      end
    end
  end
end
