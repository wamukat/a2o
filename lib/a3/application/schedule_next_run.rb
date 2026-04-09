# frozen_string_literal: true

module A3
  module Application
    class ScheduleNextRun
      Result = Struct.new(:task, :phase, :started_run, keyword_init: true)

      def initialize(plan_next_runnable_task:, start_run:, build_scope_snapshot:, build_artifact_owner:, phase_source_policy: A3::Domain::PhaseSourcePolicy.new, integration_ref_readiness_checker:)
        @plan_next_runnable_task = plan_next_runnable_task
        @start_run = start_run
        @build_scope_snapshot = build_scope_snapshot
        @build_artifact_owner = build_artifact_owner
        @phase_source_policy = phase_source_policy
        raise ArgumentError, "integration_ref_readiness_checker is required" unless integration_ref_readiness_checker

        @integration_ref_readiness_checker = integration_ref_readiness_checker
      end

      def call(project_context:)
        plan = @plan_next_runnable_task.call
        return Result.new(task: nil, phase: nil, started_run: nil) unless plan.task

        task = plan.task
        phase = plan.phase
        runtime = project_context.resolve_phase_runtime(task: task, phase: phase)
        source_descriptor = @phase_source_policy.source_descriptor_for(task: task, phase: phase)
        assert_integration_ref_readiness!(task: task, phase: phase, source_descriptor: source_descriptor)
        started_run = @start_run.call(
          task_ref: task.ref,
          phase: phase,
          source_descriptor: source_descriptor,
          scope_snapshot: @build_scope_snapshot.call(task: task),
          review_target: @phase_source_policy.review_target_for(
            task: task,
            phase: phase,
            source_ref: source_descriptor.ref
          ),
          artifact_owner: @build_artifact_owner.call(
            task: task,
            snapshot_version: source_descriptor.ref
          ),
          bootstrap_marker: runtime.workspace_hook
        )

        Result.new(task: task, phase: phase, started_run: started_run)
      end

      private

      def assert_integration_ref_readiness!(task:, phase:, source_descriptor:)
        return unless task.kind == :parent
        return unless %i[review verification merge].include?(phase.to_sym)

        result = @integration_ref_readiness_checker.check(
          ref: source_descriptor.ref,
          repo_slots: task.edit_scope
        )
        return if result.ready?

        raise A3::Domain::ConfigurationError, result.diagnostic_summary
      end
    end
  end
end
