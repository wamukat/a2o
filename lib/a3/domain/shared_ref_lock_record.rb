# frozen_string_literal: true

module A3
  module Domain
    class SharedRefLockRecord
      OPERATIONS = %i[publish merge].freeze

      attr_reader :lock_ref, :project_key, :operation, :repo_slot, :target_ref, :run_ref, :claimed_at, :heartbeat_at

      def initialize(lock_ref:, operation:, repo_slot:, target_ref:, run_ref:, claimed_at:, heartbeat_at: nil, project_key: A3::Domain::ProjectIdentity.current)
        @lock_ref = required_string(lock_ref, "lock_ref")
        @project_key = A3::Domain::ProjectIdentity.normalize(project_key)
        @operation = normalize_operation(operation)
        @repo_slot = required_string(repo_slot, "repo_slot").to_sym
        @target_ref = required_string(target_ref, "target_ref")
        @run_ref = required_string(run_ref, "run_ref")
        @claimed_at = required_string(claimed_at, "claimed_at")
        @heartbeat_at = heartbeat_at&.to_s
        freeze
      end

      def self.from_persisted_form(record)
        A3::Domain::ProjectIdentity.require_readable!(
          project_key: record["project_key"],
          record_type: "shared ref lock record"
        )
        new(
          lock_ref: record.fetch("lock_ref"),
          project_key: record["project_key"],
          operation: record.fetch("operation"),
          repo_slot: record.fetch("repo_slot"),
          target_ref: record.fetch("target_ref"),
          run_ref: record.fetch("run_ref"),
          claimed_at: record.fetch("claimed_at"),
          heartbeat_at: record["heartbeat_at"]
        )
      end

      def persisted_form
        {
          "lock_ref" => lock_ref,
          "project_key" => project_key,
          "operation" => operation.to_s,
          "repo_slot" => repo_slot.to_s,
          "target_ref" => target_ref,
          "run_ref" => run_ref,
          "claimed_at" => claimed_at,
          "heartbeat_at" => heartbeat_at
        }.compact
      end

      def shared_ref_key
        self.class.shared_ref_key(repo_slot: repo_slot, target_ref: target_ref)
      end

      def self.shared_ref_key(repo_slot:, target_ref:)
        "shared-ref:#{repo_slot}:#{target_ref}"
      end

      private

      def normalize_operation(value)
        operation = required_string(value, "operation").to_sym
        return operation if OPERATIONS.include?(operation)

        raise ConfigurationError, "unsupported shared ref lock operation: #{value.inspect}"
      end

      def required_string(value, field)
        normalized = value.to_s.strip
        raise ConfigurationError, "shared ref lock #{field} must be provided" if normalized.empty?

        normalized
      end
    end
  end
end
