# frozen_string_literal: true

module A3
  module Domain
    class AgentJobRecord
      STATES = %i[queued claimed completed].freeze

      attr_reader :request, :project_key, :state, :claimed_by, :claimed_at, :heartbeat_at, :result

      def initialize(request:, state:, claimed_by: nil, claimed_at: nil, heartbeat_at: nil, result: nil, project_key: request.project_key)
        @request = request
        @project_key = A3::Domain::ProjectIdentity.normalize(project_key)
        @state = normalize_state(state)
        @claimed_by = claimed_by&.to_s
        @claimed_at = claimed_at&.to_s
        @heartbeat_at = heartbeat_at&.to_s
        @result = result
        validate_claim!
        validate_result!
        validate_project_identity!
        freeze
      end

      def self.from_persisted_form(record)
        project_key = record["project_key"] || record.dig("request", "project_key")
        A3::Domain::ProjectIdentity.require_readable!(project_key: project_key, record_type: "agent job record")
        new(
          request: AgentJobRequest.from_request_form(record.fetch("request")),
          project_key: project_key,
          state: record.fetch("state"),
          claimed_by: record["claimed_by"],
          claimed_at: record["claimed_at"],
          heartbeat_at: record["heartbeat_at"],
          result: record["result"] && AgentJobResult.from_result_form(record["result"])
        )
      end

      def persisted_form
        {
          "project_key" => project_key,
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
          project_key: project_key,
          state: :claimed,
          claimed_by: agent_name,
          claimed_at: claimed_at
        )
      end

      def heartbeat(heartbeat_at:)
        return self if state == :completed

        raise ConfigurationError, "agent job #{job_id} is not claimed" unless state == :claimed

        self.class.new(
          request: request,
          project_key: project_key,
          state: state,
          claimed_by: claimed_by,
          claimed_at: claimed_at,
          heartbeat_at: heartbeat_at
        )
      end

      def complete(result)
        raise ConfigurationError, "agent result job_id #{result.job_id} does not match #{job_id}" unless result.job_id == job_id
        return self if state == :completed

        self.class.new(
          request: request,
          project_key: project_key,
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

      def validate_project_identity!
        validate_nested_project_identity!("agent job request", request.project_key)
        validate_nested_project_identity!("agent job result", result.project_key) if result
      end

      def validate_nested_project_identity!(record_type, nested_project_key)
        normalized_nested = A3::Domain::ProjectIdentity.normalize(nested_project_key)
        return if project_key == normalized_nested

        raise ConfigurationError, "agent job record project_key mismatch for #{record_type}"
      end
    end
  end
end
