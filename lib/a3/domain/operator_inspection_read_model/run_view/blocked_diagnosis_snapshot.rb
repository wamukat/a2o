# frozen_string_literal: true

require_relative "../../task_phase_projection"

module A3
  module Domain
    class OperatorInspectionReadModel
      class RunView
        class BlockedDiagnosisSnapshot
          attr_reader :task_ref, :run_ref, :phase, :outcome, :summary, :expected_state, :observed_state, :failing_command, :infra_diagnostics, :worker_response_bundle, :error_category, :remediation_summary

          def initialize(task_ref:, run_ref:, phase:, outcome:, summary:, expected_state:, observed_state:, failing_command:, infra_diagnostics:, worker_response_bundle:, error_category:, remediation_summary:)
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
            @error_category = error_category
            @remediation_summary = remediation_summary
            freeze
          end

          def self.from_phase_record(phase_record, task_kind: nil)
            diagnosis = phase_record&.blocked_diagnosis
            return nil unless diagnosis
            diagnostics = phase_record.execution_record&.diagnostics
            worker_response_bundle = diagnostics&.fetch("worker_response_bundle", nil)
            effective_task_kind = task_kind || phase_record.execution_record&.runtime_snapshot&.task_kind

            new(
              task_ref: diagnosis.task_ref,
              run_ref: diagnosis.run_ref,
              phase: canonical_phase(task_kind: effective_task_kind, phase: phase_record.phase),
              outcome: diagnosis.outcome,
              summary: diagnosis.diagnostic_summary,
              expected_state: diagnosis.expected_state,
              observed_state: diagnosis.observed_state,
              failing_command: diagnosis.failing_command,
              infra_diagnostics: diagnosis.infra_diagnostics,
              worker_response_bundle: worker_response_bundle,
              error_category: diagnosis.error_category,
              remediation_summary: diagnosis.remediation_summary
            )
          end

          def self.canonical_phase(task_kind:, phase:)
            return phase.to_sym unless task_kind

            A3::Domain::TaskPhaseProjection.phase_for(task_kind: task_kind, phase: phase)
          end
        end
      end
    end
  end
end
