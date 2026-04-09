# frozen_string_literal: true

module A3
  module Domain
    class OperatorInspectionReadModel
      class RunView
        class BlockedDiagnosisSnapshot
          attr_reader :task_ref, :run_ref, :phase, :outcome, :summary, :expected_state, :observed_state, :failing_command, :infra_diagnostics, :worker_response_bundle

          def initialize(task_ref:, run_ref:, phase:, outcome:, summary:, expected_state:, observed_state:, failing_command:, infra_diagnostics:, worker_response_bundle:)
            @task_ref = task_ref
            @run_ref = run_ref
            @phase = phase.to_sym
            @outcome = outcome.to_sym
            @summary = summary
            @expected_state = expected_state
            @observed_state = observed_state
            @failing_command = failing_command
            @infra_diagnostics = infra_diagnostics
            @worker_response_bundle = worker_response_bundle
            freeze
          end

          def self.from_phase_record(phase_record)
            diagnosis = phase_record&.blocked_diagnosis
            return nil unless diagnosis
            diagnostics = phase_record.execution_record&.diagnostics
            worker_response_bundle = diagnostics&.fetch("worker_response_bundle", nil)

            new(
              task_ref: diagnosis.task_ref,
              run_ref: diagnosis.run_ref,
              phase: phase_record.phase,
              outcome: diagnosis.outcome,
              summary: diagnosis.diagnostic_summary,
              expected_state: diagnosis.expected_state,
              observed_state: diagnosis.observed_state,
              failing_command: diagnosis.failing_command,
              infra_diagnostics: diagnosis.infra_diagnostics,
              worker_response_bundle: worker_response_bundle
            )
          end
        end
      end
    end
  end
end
