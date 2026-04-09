# frozen_string_literal: true

module A3
  module Domain
    class PhaseRecord
      attr_reader :phase, :source_descriptor, :scope_snapshot, :verification_summary, :execution_record, :blocked_diagnosis

      def initialize(phase:, source_descriptor:, scope_snapshot:, verification_summary: nil, execution_record: nil, blocked_diagnosis: nil)
        @phase = phase.to_sym
        @source_descriptor = source_descriptor
        @scope_snapshot = scope_snapshot
        @verification_summary = verification_summary
        @execution_record = execution_record
        @blocked_diagnosis = blocked_diagnosis
        freeze
      end

      def self.from_persisted_form(record)
        new(
          phase: record.fetch("phase"),
          source_descriptor: SourceDescriptor.from_persisted_form(record.fetch("source_descriptor")),
          scope_snapshot: ScopeSnapshot.from_persisted_form(record.fetch("scope_snapshot")),
          verification_summary: record["verification_summary"],
          execution_record: PhaseExecutionRecord.from_persisted_form(record["execution_record"]),
          blocked_diagnosis: BlockedDiagnosis.from_persisted_form(record["blocked_diagnosis"])
        )
      end

      def persisted_form
        {
          "phase" => phase.to_s,
          "source_descriptor" => source_descriptor.persisted_form,
          "scope_snapshot" => scope_snapshot.persisted_form,
          "verification_summary" => verification_summary,
          "execution_record" => execution_record&.persisted_form,
          "blocked_diagnosis" => blocked_diagnosis&.persisted_form
        }
      end

      def with_execution_record(execution_record)
        self.class.new(
          phase: phase,
          source_descriptor: source_descriptor,
          scope_snapshot: scope_snapshot,
          verification_summary: verification_summary,
          execution_record: execution_record,
          blocked_diagnosis: blocked_diagnosis
        )
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.phase == phase &&
          other.source_descriptor == source_descriptor &&
          other.scope_snapshot == scope_snapshot &&
          other.verification_summary == verification_summary &&
          other.execution_record == execution_record &&
          other.blocked_diagnosis == blocked_diagnosis
      end
      alias eql? ==
    end
  end
end
