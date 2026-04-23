# frozen_string_literal: true

require "a3/domain/upstream_line_guard"

module A3
  module Application
    class ScheduleNextRun
      Result = Struct.new(:task, :phase, :started_run, keyword_init: true)

      def initialize(plan_next_runnable_task:, start_run:, build_scope_snapshot:, build_artifact_owner:, run_repository:, phase_source_policy: A3::Domain::PhaseSourcePolicy.new, integration_ref_readiness_checker:, upstream_line_guard: A3::Domain::UpstreamLineGuard.new)
        @plan_next_runnable_task = plan_next_runnable_task
        @start_run = start_run
        @build_scope_snapshot = build_scope_snapshot
        @build_artifact_owner = build_artifact_owner
        @run_repository = run_repository
        @phase_source_policy = phase_source_policy
        @upstream_line_guard = upstream_line_guard
        raise ArgumentError, "integration_ref_readiness_checker is required" unless integration_ref_readiness_checker

        @integration_ref_readiness_checker = integration_ref_readiness_checker
      end

      def call(project_context:)
        plan = @plan_next_runnable_task.call
        task, phase = next_schedulable_candidate(plan)
        return Result.new(task: nil, phase: nil, started_run: nil) unless task

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

      def next_schedulable_candidate(plan)
        tasks = plan.assessments.map(&:task)
        runs = @run_repository.all

        runnable_assessments = plan.assessments
          .select(&:runnable?)
          .sort_by { |assessment| [-assessment.task.priority, assessment.task.ref] }

        runnable_assessments.each do |assessment|
          next unless assessment.runnable?
          next unless upstream_healthy?(task: assessment.task, phase: assessment.phase, tasks: tasks, runs: runs)

          return [assessment.task, assessment.phase]
        end

        [nil, nil]
      end

      def upstream_healthy?(task:, phase:, tasks:, runs:)
        @upstream_line_guard.evaluate(
          task: task,
          phase: phase,
          tasks: tasks,
          runs: runs
        ).healthy?
      end

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
