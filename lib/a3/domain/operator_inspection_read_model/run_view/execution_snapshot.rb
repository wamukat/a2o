# frozen_string_literal: true

require_relative "../../task_phase_projection"

module A3
  module Domain
    class OperatorInspectionReadModel
      class RunView
        class ExecutionSnapshot
          attr_reader :phase, :summary, :verification_summary, :failing_command, :observed_state, :diagnostics, :worker_response_bundle, :merge_recovery, :runtime_snapshot, :review_disposition, :agent_artifacts

          def initialize(phase:, summary:, verification_summary:, failing_command:, observed_state:, diagnostics:, worker_response_bundle:, runtime_snapshot:, review_disposition:, agent_artifacts: [], merge_recovery: nil)
            @phase = phase.to_sym
            @summary = summary
            @verification_summary = verification_summary
            @failing_command = failing_command
            @observed_state = observed_state
            @diagnostics = diagnostics
            @worker_response_bundle = worker_response_bundle
            @merge_recovery = merge_recovery
            @runtime_snapshot = runtime_snapshot
            @review_disposition = review_disposition
            @agent_artifacts = Array(agent_artifacts).freeze
            freeze
          end

          def self.from_phase_record(phase_record, task_kind: nil)
            return nil unless phase_record&.execution_record
            diagnostics = phase_record.execution_record.diagnostics
            worker_response_bundle = diagnostics["worker_response_bundle"]
            merge_recovery = diagnostics["merge_recovery"]
            runtime_snapshot = RuntimeSnapshot.from_phase_runtime_snapshot(
              phase_record.execution_record.runtime_snapshot
            )
            effective_task_kind = task_kind || runtime_snapshot&.task_kind

            new(
              phase: canonical_phase(task_kind: effective_task_kind, phase: phase_record.phase),
              summary: phase_record.execution_record.summary,
              verification_summary: phase_record.verification_summary,
              failing_command: phase_record.execution_record.failing_command,
              observed_state: phase_record.execution_record.observed_state,
              diagnostics: diagnostics,
              worker_response_bundle: worker_response_bundle,
              merge_recovery: merge_recovery,
              review_disposition: phase_record.execution_record.review_disposition,
              agent_artifacts: agent_artifacts_from_diagnostics(diagnostics),
              runtime_snapshot: runtime_snapshot
            )
          end

          def self.agent_artifacts_from_diagnostics(diagnostics)
            result = diagnostics["agent_job_result"]
            return [] unless result.is_a?(Hash)

            Array(result["log_uploads"]) + Array(result["artifact_uploads"])
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
