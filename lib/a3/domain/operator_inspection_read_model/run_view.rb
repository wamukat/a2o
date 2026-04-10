# frozen_string_literal: true

require_relative "../task_phase_projection"

module A3
  module Domain
    class OperatorInspectionReadModel
      class RunView
        attr_reader :ref, :task_ref, :task_kind, :phase, :workspace_kind, :source_type, :source_ref,
                    :terminal_outcome, :evidence_summary, :latest_execution, :latest_blocked_diagnosis,
                    :rerun_decision, :recovery

        def initialize(ref:, task_ref:, task_kind: nil, phase:, workspace_kind:, source_type:, source_ref:, terminal_outcome:, evidence_summary:, latest_execution:, latest_blocked_diagnosis:, rerun_decision:, recovery:)
          @ref = ref
          @task_ref = task_ref
          @task_kind = task_kind&.to_sym
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

        def self.from_run(run, recovery:, task_kind: nil)
          latest_phase_record = run.phase_records.last
          latest_blocked_phase_record = run.phase_records.reverse_each.find { |phase_record| !phase_record.blocked_diagnosis.nil? }
          canonical_task_kind = effective_task_kind(
            explicit_task_kind: task_kind,
            latest_phase_record: latest_phase_record
          )

          new(
            ref: run.ref,
            task_ref: run.task_ref,
            task_kind: canonical_task_kind,
            phase: canonical_phase(task_kind: canonical_task_kind, phase: run.phase),
            workspace_kind: run.workspace_kind,
            source_type: run.source_descriptor.source_type,
            source_ref: run.source_descriptor.ref,
            terminal_outcome: run.terminal_outcome,
            evidence_summary: EvidenceSummary.from_evidence(run.evidence),
            latest_execution: ExecutionSnapshot.from_phase_record(latest_phase_record, task_kind: canonical_task_kind),
            latest_blocked_diagnosis: BlockedDiagnosisSnapshot.from_phase_record(latest_blocked_phase_record, task_kind: canonical_task_kind),
            rerun_decision: recovery&.decision,
            recovery: recovery
          )
        end

        def self.effective_task_kind(explicit_task_kind:, latest_phase_record:)
          return explicit_task_kind&.to_sym if explicit_task_kind

          latest_phase_record&.execution_record&.runtime_snapshot&.task_kind&.to_sym
        end

        def self.canonical_phase(task_kind:, phase:)
          return phase.to_sym unless task_kind

          A3::Domain::TaskPhaseProjection.phase_for(task_kind: task_kind, phase: phase)
        end
      end
    end
  end
end
