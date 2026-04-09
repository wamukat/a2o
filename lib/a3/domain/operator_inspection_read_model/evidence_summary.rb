# frozen_string_literal: true

module A3
  module Domain
    class OperatorInspectionReadModel
      class EvidenceSummary
        attr_reader :workspace_kind, :source_type, :source_ref, :review_base, :review_head,
                    :edit_scope, :verification_scope, :ownership_scope,
                    :artifact_owner_ref, :artifact_owner_scope, :artifact_snapshot_version,
                    :phase_records_count

        def initialize(workspace_kind:, source_type:, source_ref:, review_base:, review_head:,
                       edit_scope:, verification_scope:, ownership_scope:,
                       artifact_owner_ref:, artifact_owner_scope:, artifact_snapshot_version:,
                       phase_records_count:)
          @workspace_kind = workspace_kind.to_sym
          @source_type = source_type.to_sym
          @source_ref = source_ref
          @review_base = review_base
          @review_head = review_head
          @edit_scope = Array(edit_scope).map(&:to_sym).freeze
          @verification_scope = Array(verification_scope).map(&:to_sym).freeze
          @ownership_scope = ownership_scope.to_sym
          @artifact_owner_ref = artifact_owner_ref
          @artifact_owner_scope = artifact_owner_scope&.to_sym
          @artifact_snapshot_version = artifact_snapshot_version
          @phase_records_count = Integer(phase_records_count)
          freeze
        end

        def self.from_evidence(evidence)
          review_target = evidence.review_target
          artifact_owner = evidence.artifact_owner

          new(
            workspace_kind: evidence.source_descriptor.workspace_kind,
            source_type: evidence.source_descriptor.source_type,
            source_ref: evidence.source_descriptor.ref,
            review_base: review_target&.base_commit,
            review_head: review_target&.head_commit,
            edit_scope: evidence.scope_snapshot.edit_scope,
            verification_scope: evidence.scope_snapshot.verification_scope,
            ownership_scope: evidence.scope_snapshot.ownership_scope,
            artifact_owner_ref: artifact_owner&.owner_ref,
            artifact_owner_scope: artifact_owner&.owner_scope,
            artifact_snapshot_version: artifact_owner&.snapshot_version,
            phase_records_count: evidence.phase_records.size
          )
        end

        def ==(other)
          other.is_a?(self.class) &&
            other.workspace_kind == workspace_kind &&
            other.source_type == source_type &&
            other.source_ref == source_ref &&
            other.review_base == review_base &&
            other.review_head == review_head &&
            other.edit_scope == edit_scope &&
            other.verification_scope == verification_scope &&
            other.ownership_scope == ownership_scope &&
            other.artifact_owner_ref == artifact_owner_ref &&
            other.artifact_owner_scope == artifact_owner_scope &&
            other.artifact_snapshot_version == artifact_snapshot_version &&
            other.phase_records_count == phase_records_count
        end
        alias eql? ==
      end
    end
  end
end
