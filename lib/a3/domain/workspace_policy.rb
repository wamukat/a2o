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

      def initialize(repo_slots: nil)
        @repo_slots = Array(repo_slots).map(&:to_sym).uniq.freeze unless repo_slots.nil?
      end

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
        slot_universe = @repo_slots || (scope_snapshot.edit_scope + scope_snapshot.verification_scope).uniq
        slot_universe.map do |repo_slot|
          sync_class = scope_snapshot.edit_scope.include?(repo_slot) ? :eager : :lazy_but_guaranteed
          SlotRequirement.new(repo_slot: repo_slot, sync_class: sync_class)
        end
      end

      def validate_source_descriptor!(phase:, workspace_kind:, source_descriptor:)
        return if source_descriptor.workspace_kind == workspace_kind

        raise ConfigurationError,
          "phase #{phase} requires #{workspace_kind} source descriptor, got #{source_descriptor.workspace_kind}"
      end
    end
  end
end
