# frozen_string_literal: true

module A3
  module Domain
    class Run
      attr_reader :ref, :task_ref, :phase, :workspace_kind, :source_descriptor, :scope_snapshot, :artifact_owner, :evidence, :terminal_outcome, :project_key

      def initialize(ref:, task_ref:, phase:, workspace_kind:, source_descriptor:, scope_snapshot:, review_target: nil, artifact_owner:, evidence: nil, terminal_outcome: nil, project_key: A3::Domain::ProjectIdentity.current)
        assign_state(
          ref: ref,
          project_key: project_key,
          task_ref: task_ref,
          phase: phase,
          workspace_kind: workspace_kind,
          source_descriptor: source_descriptor,
          scope_snapshot: scope_snapshot,
          artifact_owner: artifact_owner,
          terminal_outcome: terminal_outcome,
          evidence: evidence || build_initial_evidence(
            task_ref: task_ref,
            project_key: project_key,
            phase: phase,
            source_descriptor: source_descriptor,
            scope_snapshot: scope_snapshot,
            review_target: review_target,
            artifact_owner: artifact_owner
          )
        )
        freeze
      end

      def self.restore(ref:, task_ref:, phase:, workspace_kind:, source_descriptor:, scope_snapshot:, artifact_owner:, evidence:, terminal_outcome: nil, project_key: A3::Domain::ProjectIdentity.current)
        new(
          ref: ref,
          project_key: project_key,
          task_ref: task_ref,
          phase: phase,
          workspace_kind: workspace_kind,
          source_descriptor: source_descriptor,
          scope_snapshot: scope_snapshot,
          artifact_owner: artifact_owner,
          evidence: evidence,
          terminal_outcome: terminal_outcome
        )
      end

      def terminal?
        !terminal_outcome.nil?
      end

      def phase_records
        evidence.phase_records
      end

      def append_phase_evidence(phase:, source_descriptor:, scope_snapshot:, verification_summary: nil, execution_record: nil)
        updated_evidence = evidence.append_phase_execution(
          phase: phase,
          source_descriptor: source_descriptor,
          scope_snapshot: scope_snapshot,
          verification_summary: verification_summary,
          execution_record: execution_record
        )

        self.class.restore(
          ref: ref,
          project_key: project_key,
          task_ref: task_ref,
          phase: phase,
          workspace_kind: source_descriptor.workspace_kind,
          source_descriptor: source_descriptor,
          scope_snapshot: scope_snapshot,
          artifact_owner: artifact_owner,
          evidence: updated_evidence,
          terminal_outcome: terminal_outcome
        )
      end

      def append_blocked_diagnosis(blocked_diagnosis, execution_record: nil)
        updated_evidence = evidence.append_phase_execution(
          phase: blocked_diagnosis.phase,
          source_descriptor: blocked_diagnosis.source_descriptor,
          scope_snapshot: blocked_diagnosis.scope_snapshot,
          execution_record: execution_record || yield_execution_record_from_diagnosis(blocked_diagnosis),
          blocked_diagnosis: blocked_diagnosis
        )

        self.class.restore(
          ref: ref,
          project_key: project_key,
          task_ref: task_ref,
          phase: phase,
          workspace_kind: workspace_kind,
          source_descriptor: source_descriptor,
          scope_snapshot: scope_snapshot,
          artifact_owner: artifact_owner,
          evidence: updated_evidence,
          terminal_outcome: terminal_outcome
        )
      end

      def complete(outcome:)
        self.class.restore(
          ref: ref,
          project_key: project_key,
          task_ref: task_ref,
          phase: phase,
          workspace_kind: workspace_kind,
          source_descriptor: source_descriptor,
          scope_snapshot: scope_snapshot,
          artifact_owner: artifact_owner,
          evidence: evidence,
          terminal_outcome: outcome
        )
      end

      def replace_latest_phase_record(phase_record)
        self.class.restore(
          ref: ref,
          project_key: project_key,
          task_ref: task_ref,
          phase: phase,
          workspace_kind: workspace_kind,
          source_descriptor: source_descriptor,
          scope_snapshot: scope_snapshot,
          artifact_owner: artifact_owner,
          evidence: evidence.replace_last_phase_record(phase_record),
          terminal_outcome: terminal_outcome
        )
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.ref == ref &&
          other.project_key == project_key &&
          other.task_ref == task_ref &&
          other.phase == phase &&
          other.workspace_kind == workspace_kind &&
          other.source_descriptor == source_descriptor &&
          other.scope_snapshot == scope_snapshot &&
          other.artifact_owner == artifact_owner &&
          other.terminal_outcome == terminal_outcome &&
          other.evidence == evidence
      end
      alias eql? ==

      private

      def assign_state(ref:, task_ref:, phase:, workspace_kind:, source_descriptor:, scope_snapshot:, artifact_owner:, terminal_outcome:, evidence:, project_key:)
        validate_workspace_kind_alignment!(
          workspace_kind: workspace_kind,
          source_descriptor: source_descriptor
        )
        validate_evidence_alignment!(
          task_ref: task_ref,
          project_key: project_key,
          source_descriptor: source_descriptor,
          scope_snapshot: scope_snapshot,
          artifact_owner: artifact_owner,
          evidence: evidence
        )
        @ref = ref
        @project_key = A3::Domain::ProjectIdentity.normalize(project_key)
        @task_ref = task_ref
        @phase = phase.to_sym
        @workspace_kind = workspace_kind.to_sym
        @source_descriptor = source_descriptor
        @scope_snapshot = scope_snapshot
        @artifact_owner = artifact_owner
        @terminal_outcome = terminal_outcome&.to_sym
        @evidence = evidence
      end

      def validate_workspace_kind_alignment!(workspace_kind:, source_descriptor:)
        return if workspace_kind.to_sym == source_descriptor.workspace_kind

        raise ConfigurationError, "run evidence mismatch for workspace_kind"
      end

      def build_initial_evidence(task_ref:, phase:, source_descriptor:, scope_snapshot:, review_target:, artifact_owner:, project_key:)
        EvidenceRecord.build_initial(
          task_ref: task_ref,
          project_key: project_key,
          phase: phase,
          source_descriptor: source_descriptor,
          scope_snapshot: scope_snapshot,
          review_target: review_target,
          artifact_owner: artifact_owner
        )
      end

      def yield_execution_record_from_diagnosis(blocked_diagnosis)
        PhaseExecutionRecord.new(
          summary: blocked_diagnosis.diagnostic_summary,
          failing_command: blocked_diagnosis.failing_command,
          observed_state: blocked_diagnosis.observed_state,
          diagnostics: blocked_diagnosis.infra_diagnostics
        )
      end

      def validate_evidence_alignment!(task_ref:, project_key:, source_descriptor:, scope_snapshot:, artifact_owner:, evidence:)
        ensure_matching_evidence!(:task_ref, expected: task_ref, actual: evidence.task_ref)
        ensure_matching_evidence!(:project_key, expected: project_key, actual: evidence.project_key)
        ensure_matching_evidence!(:source_descriptor, expected: source_descriptor, actual: evidence.source_descriptor)
        ensure_matching_evidence!(:scope_snapshot, expected: scope_snapshot, actual: evidence.scope_snapshot)
        ensure_matching_evidence!(:artifact_owner, expected: artifact_owner, actual: evidence.artifact_owner)
      end

      def ensure_matching_evidence!(field_name, expected:, actual:)
        return if expected == actual

        raise ConfigurationError, "run evidence mismatch for #{field_name}"
      end
    end
  end
end
