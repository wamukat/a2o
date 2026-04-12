# frozen_string_literal: true

require "json"

module A3
  module Domain
    class AgentJobRequest
      PHASES = %i[implementation review verification merge].freeze
      MAX_WORKER_PROTOCOL_PAYLOAD_BYTES = 1024 * 1024

      attr_reader :job_id, :task_ref, :phase, :runtime_profile, :source_descriptor, :workspace_request, :merge_request, :worker_protocol_request,
                  :working_dir, :command, :args, :env, :timeout_seconds, :artifact_rules

      def initialize(job_id:, task_ref:, phase:, runtime_profile:, source_descriptor:, working_dir:, command:, args:, env:, timeout_seconds:, artifact_rules:, workspace_request: nil, merge_request: nil, worker_protocol_request: nil)
        @job_id = required_string(job_id, "job_id")
        @task_ref = required_string(task_ref, "task_ref")
        @phase = normalize_phase(phase)
        @runtime_profile = required_string(runtime_profile, "runtime_profile")
        @source_descriptor = source_descriptor
        @workspace_request = normalize_workspace_request(workspace_request)
        @merge_request = normalize_optional_json_object(merge_request, "merge_request")
        @worker_protocol_request = normalize_optional_json_object(worker_protocol_request, "worker_protocol_request")
        @working_dir = required_string(working_dir, "working_dir")
        @command = required_string(command, "command")
        @args = Array(args).map(&:to_s).freeze
        @env = normalize_string_hash(env, "env")
        @timeout_seconds = Integer(timeout_seconds)
        @artifact_rules = normalize_artifact_rules(artifact_rules)
        validate_timeout!
        freeze
      end

      def self.from_request_form(record)
        new(
          job_id: record.fetch("job_id"),
          task_ref: record.fetch("task_ref"),
          phase: record.fetch("phase"),
          runtime_profile: record.fetch("runtime_profile"),
          source_descriptor: SourceDescriptor.from_persisted_form(record.fetch("source_descriptor")),
          working_dir: record.fetch("working_dir"),
          command: record.fetch("command"),
          args: record.fetch("args"),
          env: record.fetch("env"),
          timeout_seconds: record.fetch("timeout_seconds"),
          artifact_rules: record.fetch("artifact_rules"),
          workspace_request: record["workspace_request"] && AgentWorkspaceRequest.from_request_form(record["workspace_request"]),
          merge_request: record["merge_request"],
          worker_protocol_request: record["worker_protocol_request"]
        )
      end

      def request_form
        {
          "job_id" => job_id,
          "task_ref" => task_ref,
          "phase" => phase.to_s,
          "runtime_profile" => runtime_profile,
          "source_descriptor" => source_descriptor.persisted_form,
          "workspace_request" => workspace_request&.request_form,
          "merge_request" => merge_request,
          "worker_protocol_request" => worker_protocol_request,
          "working_dir" => working_dir,
          "command" => command,
          "args" => args,
          "env" => env,
          "timeout_seconds" => timeout_seconds,
          "artifact_rules" => artifact_rules
        }.compact
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.request_form == request_form
      end
      alias eql? ==

      private

      def required_string(value, name)
        string = value.to_s
        raise ConfigurationError, "#{name} must be provided" if string.empty?

        string
      end

      def normalize_phase(value)
        normalized = value.to_sym
        return normalized if PHASES.include?(normalized)

        raise ConfigurationError, "unsupported agent job phase: #{value.inspect}"
      end

      def normalize_string_hash(value, name)
        value.each_with_object({}) do |(key, item), normalized|
          key_string = key.to_s
          raise ConfigurationError, "#{name} keys must be provided" if key_string.empty?

          normalized[key_string] = item.to_s
        end.freeze
      end

      def normalize_artifact_rules(value)
        Array(value).map do |rule|
          rule.transform_keys(&:to_s).each_with_object({}) do |(key, item), normalized|
            normalized[key] = item
          end.freeze
        end.freeze
      end

      def validate_timeout!
        raise ConfigurationError, "timeout_seconds must be positive" unless timeout_seconds.positive?
      end

      def normalize_workspace_request(value)
        return nil if value.nil?
        return value if value.is_a?(AgentWorkspaceRequest)

        AgentWorkspaceRequest.from_request_form(value)
      end

      def normalize_optional_json_object(value, name)
        return nil if value.nil?
        raise ConfigurationError, "#{name} must be a JSON object" unless value.is_a?(Hash)

        encoded = JSON.generate(value)
        raise ConfigurationError, "#{name} exceeds #{MAX_WORKER_PROTOCOL_PAYLOAD_BYTES} bytes" if encoded.bytesize > MAX_WORKER_PROTOCOL_PAYLOAD_BYTES

        JSON.parse(encoded).freeze
      end
    end
  end
end
