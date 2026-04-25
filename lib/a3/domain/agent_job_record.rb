# frozen_string_literal: true

module A3
  module Domain
    class AgentJobRecord
      STATES = %i[queued claimed completed].freeze

      attr_reader :request, :state, :claimed_by, :claimed_at, :heartbeat_at, :result

      def initialize(request:, state:, claimed_by: nil, claimed_at: nil, heartbeat_at: nil, result: nil)
        @request = request
        @state = normalize_state(state)
        @claimed_by = claimed_by&.to_s
        @claimed_at = claimed_at&.to_s
        @heartbeat_at = heartbeat_at&.to_s
        @result = result
        validate_claim!
        validate_result!
        freeze
      end

      def self.from_persisted_form(record)
        new(
          request: AgentJobRequest.from_request_form(record.fetch("request")),
          state: record.fetch("state"),
          claimed_by: record["claimed_by"],
          claimed_at: record["claimed_at"],
          heartbeat_at: record["heartbeat_at"],
          result: record["result"] && AgentJobResult.from_result_form(record["result"])
        )
      end

      def persisted_form
        {
          "request" => request.request_form,
          "state" => state.to_s,
          "claimed_by" => claimed_by,
          "claimed_at" => claimed_at,
          "heartbeat_at" => heartbeat_at,
          "result" => result&.result_form
        }.compact
      end

      def job_id
        request.job_id
      end

      def queued?
        state == :queued
      end

      def claim(agent_name:, claimed_at:)
        raise ConfigurationError, "agent job #{job_id} is not queued" unless queued?

        self.class.new(
          request: request,
          state: :claimed,
          claimed_by: agent_name,
          claimed_at: claimed_at
        )
      end

      def heartbeat(heartbeat_at:)
        raise ConfigurationError, "agent job #{job_id} is not claimed" unless state == :claimed

        self.class.new(
          request: request,
          state: state,
          claimed_by: claimed_by,
          claimed_at: claimed_at,
          heartbeat_at: heartbeat_at
        )
      end

      def complete(result)
        raise ConfigurationError, "agent job #{job_id} is already completed" if state == :completed
        raise ConfigurationError, "agent result job_id #{result.job_id} does not match #{job_id}" unless result.job_id == job_id

        self.class.new(
          request: request,
          state: :completed,
          claimed_by: claimed_by,
          claimed_at: claimed_at,
          heartbeat_at: result.heartbeat || heartbeat_at,
          result: result
        )
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.persisted_form == persisted_form
      end
      alias eql? ==

      private

      def normalize_state(value)
        normalized = value.to_sym
        return normalized if STATES.include?(normalized)

        raise ConfigurationError, "unsupported agent job state: #{value.inspect}"
      end

      def validate_claim!
        return unless state == :claimed
        return if claimed_by && claimed_at

        raise ConfigurationError, "claimed agent jobs require claimed_by and claimed_at"
      end

      def validate_result!
        return unless state == :completed
        return if result

        raise ConfigurationError, "completed agent jobs require result"
      end
    end
  end
end
