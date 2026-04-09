# frozen_string_literal: true

module A3
  module Application
    class PlanPersistedRerun
      Result = Struct.new(:task, :run, :decision, keyword_init: true)

      def initialize(task_repository:, run_repository:, plan_rerun:, build_scope_snapshot:, build_artifact_owner:)
        @task_repository = task_repository
        @run_repository = run_repository
        @plan_rerun = plan_rerun
        @build_scope_snapshot = build_scope_snapshot
        @build_artifact_owner = build_artifact_owner
      end

      def call(task_ref:, run_ref:, current_source_type:, current_source_ref:, current_review_base:, current_review_head:, snapshot_version:)
        task = @task_repository.fetch(task_ref)
        run = @run_repository.fetch(run_ref)
        current_scope_snapshot = @build_scope_snapshot.call(task: task)
        current_artifact_owner = @build_artifact_owner.call(
          task: task,
          snapshot_version: snapshot_version
        )

        rerun = @plan_rerun.call(
          run: run,
          current_source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: run.workspace_kind,
            source_type: current_source_type,
            ref: current_source_ref,
            task_ref: task.ref
          ),
          current_review_target: A3::Domain::ReviewTarget.new(
            base_commit: current_review_base,
            head_commit: current_review_head,
            task_ref: task.ref,
            phase_ref: :review
          ),
          current_scope_snapshot: current_scope_snapshot,
          current_artifact_owner: current_artifact_owner
        )

        Result.new(task: task, run: run, decision: rerun.decision)
      end
    end
  end
end
