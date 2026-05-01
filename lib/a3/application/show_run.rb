# frozen_string_literal: true

module A3
  module Application
    class ShowRun
      def initialize(run_repository:, task_repository:, plan_rerun:, build_scope_snapshot:, build_artifact_owner:, task_claim_repository: nil)
        @run_repository = run_repository
        @task_repository = task_repository
        @task_claim_repository = task_claim_repository
        @resolve_run_recovery = ResolveRunRecovery.new(
          plan_rerun: plan_rerun,
          build_scope_snapshot: build_scope_snapshot,
          build_artifact_owner: build_artifact_owner
        )
      end

      def call(run_ref:, runtime_package:)
        run = @run_repository.fetch(run_ref)
        task = @task_repository.fetch(run.task_ref)

        recovery = @resolve_run_recovery.call(task: task, run: run, runtime_package: runtime_package)

        A3::Domain::OperatorInspectionReadModel::RunView.from_run(
          run,
          recovery: recovery.recovery,
          task_kind: task.kind,
          claim_ref: active_claim_for(run: run, task: task)&.claim_ref
        )
      end

      private

      def active_claim_for(run:, task:)
        return nil unless @task_claim_repository

        @task_claim_repository.active_claims.find do |claim|
          claim.run_ref == run.ref ||
            (claim.run_ref.nil? && claim.task_ref == run.task_ref && task.current_run_ref == run.ref)
        end
      end
    end
  end
end
