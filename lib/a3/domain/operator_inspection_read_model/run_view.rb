# frozen_string_literal: true

module A3
  module Domain
    class OperatorInspectionReadModel
      class RunView
        attr_reader :ref, :task_ref, :phase, :workspace_kind, :source_type, :source_ref,
                    :terminal_outcome, :evidence_summary, :latest_execution, :latest_blocked_diagnosis,
                    :rerun_decision, :recovery

        def initialize(ref:, task_ref:, phase:, workspace_kind:, source_type:, source_ref:, terminal_outcome:, evidence_summary:, latest_execution:, latest_blocked_diagnosis:, rerun_decision:, recovery:)
          @ref = ref
          @task_ref = task_ref
          @phase = phase.to_sym
          @workspace_kind = workspace_kind.to_sym
          @source_type = source_type.to_sym
          @source_ref = source_ref
          @terminal_outcome = terminal_outcome&.to_sym
          @evidence_summary = evidence_summary
          @latest_execution = latest_execution
          @latest_blocked_diagnosis = latest_blocked_diagnosis
          @rerun_decision = rerun_decision&.to_sym
          @recovery = recovery
          freeze
        end

        def self.from_run(run, recovery:)
          latest_phase_record = run.phase_records.last
          latest_blocked_phase_record = run.phase_records.reverse_each.find { |phase_record| !phase_record.blocked_diagnosis.nil? }

          new(
            ref: run.ref,
            task_ref: run.task_ref,
            phase: run.phase,
            workspace_kind: run.workspace_kind,
            source_type: run.source_descriptor.source_type,
            source_ref: run.source_descriptor.ref,
            terminal_outcome: run.terminal_outcome,
            evidence_summary: EvidenceSummary.from_evidence(run.evidence),
            latest_execution: ExecutionSnapshot.from_phase_record(latest_phase_record),
            latest_blocked_diagnosis: BlockedDiagnosisSnapshot.from_phase_record(latest_blocked_phase_record),
            rerun_decision: recovery&.decision,
            recovery: recovery
          )
        end
      end
    end
  end
end
