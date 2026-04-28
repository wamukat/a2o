# frozen_string_literal: true

module A3
  module Domain
    class EvidenceRecord
      attr_reader :task_ref, :review_target, :source_descriptor, :scope_snapshot, :artifact_owner, :phase_records, :project_key

      def self.build_initial(task_ref:, phase:, source_descriptor:, scope_snapshot:, review_target:, artifact_owner:, project_key: A3::Domain::ProjectIdentity.current)
        new(
          task_ref: task_ref,
          project_key: project_key,
          review_target: review_target,
          source_descriptor: source_descriptor,
          scope_snapshot: scope_snapshot,
          artifact_owner: artifact_owner,
          phase_records: [
            PhaseRecord.new(
              phase: phase,
              source_descriptor: source_descriptor,
              scope_snapshot: scope_snapshot
            )
          ]
        )
      end

      def initialize(task_ref:, review_target:, source_descriptor:, scope_snapshot:, artifact_owner:, phase_records:, project_key: A3::Domain::ProjectIdentity.current)
        @task_ref = task_ref
        @project_key = A3::Domain::ProjectIdentity.normalize(project_key)
        @review_target = review_target
        @source_descriptor = source_descriptor
        @scope_snapshot = scope_snapshot
        @artifact_owner = artifact_owner
        @phase_records = phase_records.freeze
        freeze
      end

      def self.from_persisted_form(record)
        A3::Domain::ProjectIdentity.require_readable!(project_key: record["project_key"], record_type: "evidence")
        new(
          task_ref: record.fetch("task_ref"),
          project_key: record["project_key"],
          review_target: ReviewTarget.from_persisted_form(record["review_target"]),
          source_descriptor: SourceDescriptor.from_persisted_form(record.fetch("source_descriptor")),
          scope_snapshot: ScopeSnapshot.from_persisted_form(record.fetch("scope_snapshot")),
          artifact_owner: ArtifactOwner.from_persisted_form(record["artifact_owner"]),
          phase_records: record.fetch("phase_records").map { |phase_record| PhaseRecord.from_persisted_form(phase_record) }
        )
      end

      def persisted_form
        {
          "task_ref" => task_ref,
          "project_key" => project_key,
          "review_target" => review_target&.persisted_form,
          "source_descriptor" => source_descriptor.persisted_form,
          "scope_snapshot" => scope_snapshot.persisted_form,
          "artifact_owner" => artifact_owner&.persisted_form,
          "phase_records" => phase_records.map(&:persisted_form)
        }.compact
      end

      def append_phase_record(phase_record)
        self.class.new(
          task_ref: task_ref,
          project_key: project_key,
          review_target: review_target,
          source_descriptor: source_descriptor,
          scope_snapshot: scope_snapshot,
          artifact_owner: artifact_owner,
          phase_records: phase_records + [phase_record]
        )
      end

      def append_phase_execution(phase:, source_descriptor:, scope_snapshot:, verification_summary: nil, execution_record: nil, blocked_diagnosis: nil)
        append_phase_record(
          PhaseRecord.new(
            phase: phase,
            source_descriptor: source_descriptor,
            scope_snapshot: scope_snapshot,
            verification_summary: verification_summary,
            execution_record: execution_record,
            blocked_diagnosis: blocked_diagnosis
          )
        )
      end

      def replace_last_phase_record(phase_record)
        self.class.new(
          task_ref: task_ref,
          project_key: project_key,
          review_target: review_target,
          source_descriptor: source_descriptor,
          scope_snapshot: scope_snapshot,
          artifact_owner: artifact_owner,
          phase_records: phase_records[0...-1] + [phase_record]
        )
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.task_ref == task_ref &&
          other.project_key == project_key &&
          other.review_target == review_target &&
          other.source_descriptor == source_descriptor &&
          other.scope_snapshot == scope_snapshot &&
          other.artifact_owner == artifact_owner &&
          other.phase_records == phase_records
      end
      alias eql? ==
    end
  end
end
