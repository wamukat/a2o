# frozen_string_literal: true

require "json"

module A3
  module Domain
    class AgentJobResult
      STATUSES = %i[succeeded failed timed_out cancelled stale].freeze
      MAX_WORKER_PROTOCOL_PAYLOAD_BYTES = 1024 * 1024

      attr_reader :job_id, :status, :exit_code, :started_at, :finished_at, :summary,
                  :log_uploads, :artifact_uploads, :workspace_descriptor, :heartbeat
      attr_reader :worker_protocol_result

      def initialize(job_id:, status:, exit_code:, started_at:, finished_at:, summary:, log_uploads:, artifact_uploads:, workspace_descriptor:, heartbeat:, worker_protocol_result: nil)
        @job_id = required_string(job_id, "job_id")
        @status = normalize_status(status)
        @exit_code = exit_code.nil? ? nil : Integer(exit_code)
        @started_at = required_string(started_at, "started_at")
        @finished_at = required_string(finished_at, "finished_at")
        @summary = required_string(summary, "summary")
        @log_uploads = normalize_uploads(log_uploads)
        @artifact_uploads = normalize_uploads(artifact_uploads)
        @workspace_descriptor = workspace_descriptor
        @worker_protocol_result = normalize_optional_json_object(worker_protocol_result, "worker_protocol_result")
        @heartbeat = heartbeat&.to_s
        validate_exit_code!
        freeze
      end

      def self.from_result_form(record)
        reject_local_path_result!(record)
        new(
          job_id: record.fetch("job_id"),
          status: record.fetch("status"),
          exit_code: record["exit_code"],
          started_at: record.fetch("started_at"),
          finished_at: record.fetch("finished_at"),
          summary: record.fetch("summary"),
          log_uploads: record.fetch("log_uploads"),
          artifact_uploads: record.fetch("artifact_uploads"),
          workspace_descriptor: AgentWorkspaceDescriptor.from_persisted_form(record.fetch("workspace_descriptor")),
          worker_protocol_result: record["worker_protocol_result"],
          heartbeat: record["heartbeat"]
        )
      end

      def result_form
        {
          "job_id" => job_id,
          "status" => status.to_s,
          "exit_code" => exit_code,
          "started_at" => started_at,
          "finished_at" => finished_at,
          "summary" => summary,
          "log_uploads" => log_uploads.map(&:persisted_form),
          "artifact_uploads" => artifact_uploads.map(&:persisted_form),
          "workspace_descriptor" => workspace_descriptor.persisted_form,
          "worker_protocol_result" => worker_protocol_result,
          "heartbeat" => heartbeat
        }.compact
      end

      def succeeded?
        status == :succeeded
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.result_form == result_form
      end
      alias eql? ==

      def self.reject_local_path_result!(record)
        path_keys = record.keys.map(&:to_s) & %w[stdout_log stderr_log combined_log artifacts]
        return if path_keys.empty?

        raise ConfigurationError, "agent job result must use upload references, not local path fields: #{path_keys.join(", ")}"
      end

      private_class_method :reject_local_path_result!

      private

      def required_string(value, name)
        string = value.to_s
        raise ConfigurationError, "#{name} must be provided" if string.empty?

        string
      end

      def normalize_status(value)
        normalized = value.to_sym
        return normalized if STATUSES.include?(normalized)

        raise ConfigurationError, "unsupported agent job status: #{value.inspect}"
      end

      def normalize_uploads(value)
        Array(value).map do |upload|
          upload.is_a?(AgentArtifactUpload) ? upload : AgentArtifactUpload.from_persisted_form(upload)
        end.freeze
      end

      def normalize_optional_json_object(value, name)
        return nil if value.nil?
        raise ConfigurationError, "#{name} must be a JSON object" unless value.is_a?(Hash)

        encoded = JSON.generate(value)
        raise ConfigurationError, "#{name} exceeds #{MAX_WORKER_PROTOCOL_PAYLOAD_BYTES} bytes" if encoded.bytesize > MAX_WORKER_PROTOCOL_PAYLOAD_BYTES

        JSON.parse(encoded).freeze
      end

      def validate_exit_code!
        return if status == :timed_out || status == :cancelled || !exit_code.nil?

        raise ConfigurationError, "exit_code must be provided for agent job status #{status}"
      end
    end
  end
end
