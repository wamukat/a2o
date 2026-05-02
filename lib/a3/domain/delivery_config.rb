# frozen_string_literal: true

module A3
  module Domain
    class DeliveryConfig
      MODES = %i[local_merge remote_branch].freeze
      INTEGRATE_BASE_VALUES = %w[none merge rebase].freeze
      CONFLICT_POLICIES = %w[stop].freeze

      attr_reader :mode, :remote, :base_branch, :branch_prefix, :push, :sync, :after_push_command

      def initialize(mode: :local_merge, remote: nil, base_branch: nil, branch_prefix: "a2o/", push: true, sync: {}, after_push_command: nil)
        @mode = normalized_mode(mode)
        @remote = optional_string(remote, "remote")
        @base_branch = optional_string(base_branch, "base_branch")
        @branch_prefix = branch_prefix.nil? ? "a2o/" : required_string(branch_prefix, "branch_prefix")
        @push = normalize_boolean(push, "push")
        @sync = normalize_sync(sync)
        @after_push_command = normalize_command(after_push_command)
        validate!
        freeze
      end

      def self.local_merge
        new
      end

      def remote_branch?
        mode == :remote_branch
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.mode == mode &&
          other.remote == remote &&
          other.base_branch == base_branch &&
          other.branch_prefix == branch_prefix &&
          other.push == push &&
          other.sync == sync &&
          other.after_push_command == after_push_command
      end
      alias eql? ==

      def persisted_form
        {
          "mode" => mode.to_s,
          "remote" => remote,
          "base_branch" => base_branch,
          "branch_prefix" => branch_prefix,
          "push" => push,
          "sync" => sync,
          "after_push_command" => after_push_command
        }.compact
      end

      private

      def normalized_mode(value)
        normalized = value.to_s.strip
        raise ConfigurationError, "project.yaml runtime.delivery.mode must be provided" if normalized.empty?

        mode_value = normalized.to_sym
        unless MODES.include?(mode_value)
          raise ConfigurationError, "unsupported project.yaml runtime.delivery.mode: #{normalized}"
        end
        mode_value
      end

      def optional_string(value, field)
        return nil if value.nil?
        unless value.is_a?(String)
          raise ConfigurationError, "project.yaml runtime.delivery.#{field} must be a string"
        end
        normalized = value.strip
        normalized.empty? ? nil : normalized
      end

      def normalize_boolean(value, field)
        return value if value == true || value == false

        raise ConfigurationError, "project.yaml runtime.delivery.#{field} must be true or false"
      end

      def normalize_sync(value)
        value ||= {}
        unless value.is_a?(Hash)
          raise ConfigurationError, "project.yaml runtime.delivery.sync must be a mapping"
        end
        normalized = {
          "before_start" => sync_action(value.fetch("before_start", "fetch"), "before_start"),
          "before_resume" => sync_action(value.fetch("before_resume", "fetch"), "before_resume"),
          "before_push" => sync_action(value.fetch("before_push", "fetch"), "before_push"),
          "integrate_base" => sync_enum(value.fetch("integrate_base", "none"), "integrate_base", INTEGRATE_BASE_VALUES),
          "conflict_policy" => sync_enum(value.fetch("conflict_policy", "stop"), "conflict_policy", CONFLICT_POLICIES)
        }
        normalized.freeze
      end

      def sync_action(value, field)
        action = required_string(value, "sync.#{field}")
        return action if action == "fetch"

        raise ConfigurationError, "project.yaml runtime.delivery.sync.#{field} must be fetch"
      end

      def sync_enum(value, field, allowed)
        item = required_string(value, "sync.#{field}")
        return item if allowed.include?(item)

        raise ConfigurationError, "unsupported project.yaml runtime.delivery.sync.#{field}: #{item}"
      end

      def required_string(value, field)
        unless value.is_a?(String)
          raise ConfigurationError, "project.yaml runtime.delivery.#{field} must be a string"
        end
        normalized = value.strip
        raise ConfigurationError, "project.yaml runtime.delivery.#{field} must not be blank" if normalized.empty?

        normalized
      end

      def normalize_command(value)
        return nil if value.nil?
        unless value.is_a?(Hash)
          raise ConfigurationError, "project.yaml runtime.delivery.after_push must be a mapping"
        end
        command = value.fetch("command", nil)
        unless command.is_a?(Array) && !command.empty?
          raise ConfigurationError, "project.yaml runtime.delivery.after_push.command must be a non-empty array of strings"
        end
        command.map.with_index do |part, index|
          unless part.is_a?(String) && !part.strip.empty?
            raise ConfigurationError, "project.yaml runtime.delivery.after_push.command[#{index}] must be a non-empty string"
          end
          part.strip
        end.freeze
      end

      def validate!
        return unless remote_branch?

        raise ConfigurationError, "project.yaml runtime.delivery.remote must be provided for remote_branch mode" unless remote
        raise ConfigurationError, "project.yaml runtime.delivery.base_branch must be provided for remote_branch mode" unless base_branch
        raise ConfigurationError, "project.yaml runtime.delivery.branch_prefix must not be blank" if branch_prefix.to_s.strip.empty?
      end
    end
  end
end
