# frozen_string_literal: true

require "securerandom"

module A3
  module Application
    class StartPhase
      Result = Struct.new(:run, keyword_init: true)

      def initialize(workspace_plan_builder: BuildWorkspacePlan.new, run_id_generator: -> { SecureRandom.uuid }, phase_source_policy: A3::Domain::PhaseSourcePolicy.new)
        @workspace_plan_builder = workspace_plan_builder
        @run_id_generator = run_id_generator
        @phase_source_policy = phase_source_policy
      end

      def call(task:, phase:, source_descriptor:, scope_snapshot:, review_target:, artifact_owner:)
        phase_name = phase.to_sym
        raise A3::Domain::InvalidPhaseError, "Unsupported phase #{phase_name} for #{task.kind}" unless task.supports_phase?(phase_name)

        canonical_source_descriptor = @phase_source_policy.source_descriptor_for(task: task, phase: phase_name)
        validate_source_descriptor!(phase: phase_name, canonical_source_descriptor: canonical_source_descriptor, source_descriptor: source_descriptor)

        workspace_plan = @workspace_plan_builder.call(
          phase: phase_name,
          source_descriptor: canonical_source_descriptor,
          scope_snapshot: scope_snapshot
        )
        Result.new(
          run: A3::Domain::Run.new(
            ref: @run_id_generator.call,
            task_ref: task.ref,
            phase: phase_name,
            workspace_kind: workspace_plan.workspace_kind,
            source_descriptor: workspace_plan.source_descriptor,
            scope_snapshot: scope_snapshot,
            review_target: review_target,
            artifact_owner: artifact_owner
          )
        )
      end

      private

      def validate_source_descriptor!(phase:, canonical_source_descriptor:, source_descriptor:)
        return if canonical_source_descriptor == source_descriptor

        raise A3::Domain::ConfigurationError,
          "phase #{phase} requires #{canonical_source_descriptor.workspace_kind}/#{canonical_source_descriptor.source_type} source descriptor, got #{source_descriptor.workspace_kind}/#{source_descriptor.source_type}"
      end
    end
  end
end
