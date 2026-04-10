# frozen_string_literal: true

module A3
  module Domain
    class AgentJobRequest
      PHASES = %i[implementation review verification merge].freeze

      attr_reader :job_id, :task_ref, :phase, :runtime_profile, :source_descriptor,
                  :working_dir, :command, :args, :env, :timeout_seconds, :artifact_rules

      def initialize(job_id:, task_ref:, phase:, runtime_profile:, source_descriptor:, working_dir:, command:, args:, env:, timeout_seconds:, artifact_rules:)
        @job_id = required_string(job_id, "job_id")
        @task_ref = required_string(task_ref, "task_ref")
        @phase = normalize_phase(phase)
        @runtime_profile = required_string(runtime_profile, "runtime_profile")
        @source_descriptor = source_descriptor
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
          artifact_rules: record.fetch("artifact_rules")
        )
      end

      def request_form
        {
          "job_id" => job_id,
          "task_ref" => task_ref,
          "phase" => phase.to_s,
          "runtime_profile" => runtime_profile,
          "source_descriptor" => source_descriptor.persisted_form,
          "working_dir" => working_dir,
          "command" => command,
          "args" => args,
          "env" => env,
          "timeout_seconds" => timeout_seconds,
          "artifact_rules" => artifact_rules
        }
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
    end
  end
end
