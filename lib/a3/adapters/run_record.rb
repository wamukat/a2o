# frozen_string_literal: true

module A3
  module Adapters
    module RunRecord
      module_function

      def dump(run)
        {
          "ref" => run.ref,
          "task_ref" => run.task_ref,
          "phase" => run.phase.to_s,
          "workspace_kind" => run.workspace_kind.to_s,
          "source_descriptor" => run.source_descriptor.persisted_form,
          "scope_snapshot" => run.scope_snapshot.persisted_form,
          "artifact_owner" => run.artifact_owner&.persisted_form,
          "terminal_outcome" => run.terminal_outcome&.to_s,
          "evidence" => run.evidence.persisted_form
        }
      end

      def load(record)
        A3::Domain::Run.restore(
          ref: record.fetch("ref"),
          task_ref: record.fetch("task_ref"),
          phase: record.fetch("phase"),
          workspace_kind: record.fetch("workspace_kind"),
          source_descriptor: A3::Domain::SourceDescriptor.from_persisted_form(record.fetch("source_descriptor")),
          scope_snapshot: A3::Domain::ScopeSnapshot.from_persisted_form(record.fetch("scope_snapshot")),
          artifact_owner: A3::Domain::ArtifactOwner.from_persisted_form(record["artifact_owner"]),
          terminal_outcome: record["terminal_outcome"],
          evidence: A3::Domain::EvidenceRecord.from_persisted_form(record.fetch("evidence"))
        )
      end

      def dump_phase_record(phase_record)
        {
          "phase" => phase_record.phase.to_s,
          "source_descriptor" => phase_record.source_descriptor.persisted_form,
          "scope_snapshot" => phase_record.scope_snapshot.persisted_form,
          "verification_summary" => phase_record.verification_summary,
          "execution_record" => phase_record.execution_record&.persisted_form,
          "blocked_diagnosis" => phase_record.blocked_diagnosis&.persisted_form
        }
      end

      def load_phase_record(record)
        A3::Domain::PhaseRecord.from_persisted_form(record)
      end

      def load_blocked_diagnosis(record)
        A3::Domain::BlockedDiagnosis.from_persisted_form(record)
      end

      def dump_blocked_diagnosis(blocked_diagnosis)
        blocked_diagnosis&.persisted_form
      end

      def load_evidence(record)
        A3::Domain::EvidenceRecord.from_persisted_form(record)
      end

      def dump_evidence(evidence)
        evidence.persisted_form
      end

      def load_source_descriptor(record)
        A3::Domain::SourceDescriptor.from_persisted_form(record)
      end

      def dump_source_descriptor(source_descriptor)
        source_descriptor.persisted_form
      end
    end
  end
end
