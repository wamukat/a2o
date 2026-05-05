# frozen_string_literal: true

module A3
  module Domain
    class ObserverConfig
      KNOWN_EVENTS = %w[
        phase.started
        phase.completed
        task.blocked
        task.needs_clarification
        task.completed
        task.reworked
        parent.follow_up_child_created
        runtime.idle
        runtime.error
      ].freeze
      Hook = Struct.new(:event, :command, keyword_init: true) do
        def persisted_form
          {
            "event" => event,
            "command" => command
          }
        end
      end

      attr_reader :hooks

      def self.empty
        new(hooks: [])
      end

      def self.from_project_config(value)
        return empty if value.nil?
        unless value.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.observers must be a mapping"
        end
        unsupported = value.keys.map(&:to_s) - %w[hooks]
        unless unsupported.empty?
          raise A3::Domain::ConfigurationError, "project.yaml runtime.observers.#{unsupported.first} is not supported; observers are best-effort read-only event observers"
        end

        raw_hooks = value.fetch("hooks", [])
        unless raw_hooks.is_a?(Array)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.observers.hooks must be an array"
        end

        new(hooks: raw_hooks.map.with_index { |hook, index| parse_hook(hook, index: index) })
      end

      def self.from_persisted_form(value)
        return empty if value.nil?

        new(
          hooks: Array(value.fetch("hooks", [])).map do |hook|
            Hook.new(event: hook.fetch("event"), command: Array(hook.fetch("command")))
          end
        )
      end

      def initialize(hooks:)
        @hooks = Array(hooks).map { |hook| Hook.new(event: hook.event.to_s, command: hook.command.map(&:to_s).freeze) }.freeze
        freeze
      end

      def hooks_for(event)
        hooks.select { |hook| hook.event == event.to_s }
      end

      def persisted_form
        { "hooks" => hooks.map(&:persisted_form) }
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.hooks == hooks
      end
      alias eql? ==

      def self.parse_hook(value, index:)
        path = "project.yaml runtime.observers.hooks[#{index}]"
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
