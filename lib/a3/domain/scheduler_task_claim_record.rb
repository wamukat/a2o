# frozen_string_literal: true

module A3
  module Domain
    class SchedulerTaskClaimRecord
      STATES = %i[claimed released stale].freeze

      attr_reader :claim_ref, :project_key, :task_ref, :phase, :parent_group_key,
                  :state, :claimed_by, :claimed_at, :heartbeat_at, :run_ref, :stale_reason

      def initialize(claim_ref:, task_ref:, phase:, parent_group_key:, state:, claimed_by: nil, claimed_at: nil, heartbeat_at: nil, run_ref: nil, stale_reason: nil, project_key: A3::Domain::ProjectIdentity.current)
        @claim_ref = required_string(claim_ref, "claim_ref")
        @project_key = A3::Domain::ProjectIdentity.normalize(project_key)
        @task_ref = required_string(task_ref, "task_ref")
        @phase = required_symbol(phase, "phase")
        @parent_group_key = required_string(parent_group_key, "parent_group_key")
        @state = normalize_state(state)
        @claimed_by = claimed_by&.to_s
        @claimed_at = claimed_at&.to_s
        @heartbeat_at = heartbeat_at&.to_s
        @run_ref = run_ref&.to_s
        @stale_reason = stale_reason&.to_s
        validate_claim!
        validate_terminal!
        freeze
      end

      def self.from_persisted_form(record)
        A3::Domain::ProjectIdentity.require_readable!(
          project_key: record["project_key"],
          record_type: "scheduler task claim record"
        )
        new(
          claim_ref: record.fetch("claim_ref"),
          project_key: record["project_key"],
          task_ref: record.fetch("task_ref"),
          phase: record.fetch("phase"),
          parent_group_key: record.fetch("parent_group_key"),
          state: record.fetch("state"),
          claimed_by: record["claimed_by"],
          claimed_at: record["claimed_at"],
          heartbeat_at: record["heartbeat_at"],
          run_ref: record["run_ref"],
          stale_reason: record["stale_reason"]
        )
      end

      def persisted_form
        {
          "claim_ref" => claim_ref,
          "project_key" => project_key,
          "task_ref" => task_ref,
          "phase" => phase.to_s,
          "parent_group_key" => parent_group_key,
          "state" => state.to_s,
          "claimed_by" => claimed_by,
          "claimed_at" => claimed_at,
          "heartbeat_at" => heartbeat_at,
          "run_ref" => run_ref,
          "stale_reason" => stale_reason
        }.compact
      end

      def active?
        state == :claimed
      end

      def terminal?
        state == :released || state == :stale
      end

      def link_run(run_ref:)
        raise ConfigurationError, "scheduler task claim #{claim_ref} is not active" unless active?

        self.class.new(**constructor_args(run_ref: run_ref))
      end

      def heartbeat(heartbeat_at:)
        return self if terminal?

        self.class.new(**constructor_args(heartbeat_at: heartbeat_at))
      end

      def release(run_ref: nil)
        return self if terminal?

        self.class.new(**constructor_args(state: :released, run_ref: run_ref || self.run_ref))
      end

      def mark_stale(reason:)
        return self if terminal?

        self.class.new(**constructor_args(state: :stale, stale_reason: reason))
      end

      def ==(other)
        other.is_a?(self.class) && other.persisted_form == persisted_form
      end
      alias eql? ==

      private

      def constructor_args(overrides = {})
        {
          claim_ref: claim_ref,
          project_key: project_key,
          task_ref: task_ref,
          phase: phase,
          parent_group_key: parent_group_key,
          state: state,
          claimed_by: claimed_by,
          claimed_at: claimed_at,
          heartbeat_at: heartbeat_at,
          run_ref: run_ref,
          stale_reason: stale_reason
        }.merge(overrides)
      end

      def normalize_state(value)
        normalized = required_symbol(value, "state")
        return normalized if STATES.include?(normalized)

        raise ConfigurationError, "unsupported scheduler task claim state: #{value.inspect}"
      end

      def required_symbol(value, field)
        normalized = required_string(value, field)
        normalized.to_sym
      end

      def required_string(value, field)
        normalized = value.to_s.strip
        raise ConfigurationError, "scheduler task claim #{field} must be provided" if normalized.empty?

        normalized
      end

      def validate_claim!
        return unless state == :claimed
        return if claimed_by && claimed_at

        raise ConfigurationError, "claimed scheduler task claims require claimed_by and claimed_at"
      end

      def validate_terminal!
        return unless state == :stale
        return if stale_reason && !stale_reason.empty?

        raise ConfigurationError, "stale scheduler task claims require stale_reason"
      end
    end
  end
end
