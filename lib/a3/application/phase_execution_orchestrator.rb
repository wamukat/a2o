# frozen_string_literal: true

module A3
  module Application
    class PhaseExecutionOrchestrator
      Result = Struct.new(:task, :run, :workspace, keyword_init: true)

      def initialize(run_repository:, register_completed_run:, prepare_workspace:)
        @run_repository = run_repository
        @register_completed_run = register_completed_run
        @prepare_workspace = prepare_workspace
      end

      def prepare(task:, run:, runtime:)
        @prepare_workspace.call(
          task: task,
          phase: run.phase,
          source_descriptor: run.source_descriptor,
          scope_snapshot: run.scope_snapshot,
          artifact_owner: run.artifact_owner,
          bootstrap_marker: runtime.workspace_hook
        )
      end

      def persist_and_complete(task_ref:, run_ref:, task:, run:, runtime:, execution:, verification_summary: nil, blocked_diagnosis: nil, execution_record: nil)
        runtime_snapshot = A3::Domain::PhaseRuntimeSnapshot.from_phase_runtime(runtime)
        persisted_run =
          if completion_outcome_for(task: task, run: run, execution: execution) != :blocked
            run.append_phase_evidence(
              phase: run.phase,
              source_descriptor: run.source_descriptor,
              scope_snapshot: run.scope_snapshot,
              verification_summary: verification_summary,
              execution_record: execution_record || A3::Domain::PhaseExecutionRecord.from_execution_result(
                execution,
                runtime_snapshot: runtime_snapshot
              )
            )
          else
            run.append_blocked_diagnosis(
              blocked_diagnosis,
              execution_record: execution_record || A3::Domain::PhaseExecutionRecord.from_execution_result(
                execution,
                runtime_snapshot: runtime_snapshot
              )
            )
          end

        @run_repository.save(persisted_run)
        completion = @register_completed_run.call(
          task_ref: task_ref,
          run_ref: run_ref,
          outcome: completion_outcome_for(task: task, run: run, execution: execution),
          execution: execution
        )
        Result.new(task: completion.task, run: completion.run)
      end

      private

      def completion_outcome_for(task:, run:, execution:)
        return :verification_required if execution.success? && run.phase == :merge && execution.merge_recovery_verification_required?
        return :completed if execution.success?
        if task.kind == :parent && run.phase == :review
          return :follow_up_child if execution.review_disposition&.follow_up_child?

          return :blocked
        end
        return :retryable if run.phase == :merge && execution.merge_recovery_required?
        return :rework if run.phase == :review && execution.rework_required?

        :blocked
      end
    end
  end
end
