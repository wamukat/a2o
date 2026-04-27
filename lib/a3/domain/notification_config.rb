# frozen_string_literal: true

module A3
  module Domain
    class NotificationConfig
      KNOWN_EVENTS = %w[
        task.started
        task.phase_completed
        task.blocked
        task.completed
        task.reworked
        parent.follow_up_child_created
        runtime.idle
        runtime.error
      ].freeze
      FAILURE_POLICIES = %w[best_effort blocking].freeze

      Hook = Struct.new(:event, :command, keyword_init: true) do
        def persisted_form
          {
            "event" => event,
            "command" => command
          }
        end
      end

      attr_reader :failure_policy, :hooks

      def self.empty
        new(failure_policy: "best_effort", hooks: [])
      end

      def self.from_project_config(value)
        return empty if value.nil?
        unless value.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.notifications must be a mapping"
        end

        failure_policy = value.fetch("failure_policy", "best_effort").to_s
        unless FAILURE_POLICIES.include?(failure_policy)
          raise A3::Domain::ConfigurationError,
                "project.yaml runtime.notifications.failure_policy must be one of: #{FAILURE_POLICIES.join(', ')}"
        end

        raw_hooks = value.fetch("hooks", [])
        unless raw_hooks.is_a?(Array)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.notifications.hooks must be an array"
        end

        new(
          failure_policy: failure_policy,
          hooks: raw_hooks.map.with_index { |hook, index| parse_hook(hook, index: index) }
        )
      end

      def self.from_persisted_form(value)
        return empty if value.nil?

        new(
          failure_policy: value.fetch("failure_policy", "best_effort"),
          hooks: Array(value.fetch("hooks", [])).map do |hook|
            Hook.new(event: hook.fetch("event"), command: Array(hook.fetch("command")))
          end
        )
      end

      def initialize(failure_policy:, hooks:)
        @failure_policy = failure_policy.to_s
        @hooks = Array(hooks).map { |hook| Hook.new(event: hook.event.to_s, command: hook.command.map(&:to_s).freeze) }.freeze
        freeze
      end

      def hooks_for(event)
        hooks.select { |hook| hook.event == event.to_s }
      end

      def blocking?
        failure_policy == "blocking"
      end

      def persisted_form
        {
          "failure_policy" => failure_policy,
          "hooks" => hooks.map(&:persisted_form)
        }
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.failure_policy == failure_policy &&
          other.hooks == hooks
      end
      alias eql? ==

      def self.parse_hook(value, index:)
        path = "project.yaml runtime.notifications.hooks[#{index}]"
        unless value.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "#{path} must be a mapping"
        end

        event = value.fetch("event") do
          raise A3::Domain::ConfigurationError, "#{path}.event must be provided"
        end.to_s
        unless KNOWN_EVENTS.include?(event)
          raise A3::Domain::ConfigurationError, "#{path}.event is unsupported: #{event}"
        end

        command = value.fetch("command") do
          raise A3::Domain::ConfigurationError, "#{path}.command must be provided"
        end
        unless command.is_a?(Array) && command.any? && command.all? { |entry| entry.is_a?(String) && !entry.empty? }
          raise A3::Domain::ConfigurationError, "#{path}.command must be a non-empty array of non-empty strings"
        end

        Hook.new(event: event, command: command.freeze)
      end
      private_class_method :parse_hook
    end
  end
end
