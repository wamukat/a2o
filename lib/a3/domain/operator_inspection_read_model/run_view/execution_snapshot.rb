# frozen_string_literal: true

module A3
  module Domain
    class OperatorInspectionReadModel
      class RunView
        class ExecutionSnapshot
          attr_reader :phase, :summary, :verification_summary, :failing_command, :observed_state, :diagnostics, :worker_response_bundle, :runtime_snapshot

          def initialize(phase:, summary:, verification_summary:, failing_command:, observed_state:, diagnostics:, worker_response_bundle:, runtime_snapshot:)
            @phase = phase.to_sym
            @summary = summary
            @verification_summary = verification_summary
            @failing_command = failing_command
            @observed_state = observed_state
            @diagnostics = diagnostics
            @worker_response_bundle = worker_response_bundle
            @runtime_snapshot = runtime_snapshot
            freeze
          end

          def self.from_phase_record(phase_record)
            return nil unless phase_record&.execution_record
            diagnostics = phase_record.execution_record.diagnostics
            worker_response_bundle = diagnostics["worker_response_bundle"]

            new(
              phase: phase_record.phase,
              summary: phase_record.execution_record.summary,
              verification_summary: phase_record.verification_summary,
              failing_command: phase_record.execution_record.failing_command,
              observed_state: phase_record.execution_record.observed_state,
              diagnostics: diagnostics,
              worker_response_bundle: worker_response_bundle,
              runtime_snapshot: RuntimeSnapshot.from_phase_runtime_snapshot(
                phase_record.execution_record.runtime_snapshot
              )
            )
          end
        end
      end
    end
  end
end
