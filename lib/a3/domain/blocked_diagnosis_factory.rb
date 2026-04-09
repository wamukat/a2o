# frozen_string_literal: true

module A3
  module Domain
    class BlockedDiagnosisFactory
      def call(task:, run:, execution:, expected_state:, default_failing_command:, extra_diagnostics: {})
        infra_diagnostics = execution.diagnostics.merge(extra_diagnostics)

        BlockedDiagnosis.new(
          task_ref: task.ref,
          run_ref: run.ref,
          phase: run.phase,
          outcome: :blocked,
          review_target: run.evidence.review_target,
          source_descriptor: run.evidence.source_descriptor,
          scope_snapshot: run.evidence.scope_snapshot,
          artifact_owner: run.evidence.artifact_owner,
          expected_state: expected_state,
          observed_state: execution.observed_state || default_observed_state(run.phase),
          failing_command: execution.failing_command || default_failing_command,
          diagnostic_summary: execution.summary,
          infra_diagnostics: infra_diagnostics
        )
      end

      private

      def default_observed_state(phase)
        case phase.to_sym
        when :worker
          "worker phase failed"
        else
          "#{phase} failed"
        end
      end
    end
  end
end
