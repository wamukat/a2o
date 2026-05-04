# frozen_string_literal: true

module A3
  module Domain
    module AgentWorkspacePublishPolicy
      MODES = %w[
        commit_declared_changes_on_success
        commit_all_edit_target_changes_on_worker_success
        commit_all_edit_target_changes_on_success
      ].freeze
      NATIVE_GIT_HOOK_POLICIES = %w[bypass run].freeze
      DEFAULT_NATIVE_GIT_HOOKS = "bypass"

      module_function

      def normalize_native_git_hooks(value)
        policy = required_string(value, "publish policy commit_preflight.native_git_hooks")
        return policy if NATIVE_GIT_HOOK_POLICIES.include?(policy)

        raise ConfigurationError, "unsupported agent workspace publish_policy commit_preflight.native_git_hooks: #{policy}"
      end

      def native_git_hooks_from(record)
        commit_preflight_record(record).fetch("native_git_hooks", DEFAULT_NATIVE_GIT_HOOKS).to_s
      end

      def commands_from(record)
        commands = commit_preflight_record(record).fetch("commands", [])
        unless commands.is_a?(Array)
          raise ConfigurationError, "agent workspace publish_policy commit_preflight.commands must be an array"
        end
        commands.map.with_index do |command, index|
          unless command.is_a?(String)
            raise ConfigurationError, "agent workspace publish_policy commit_preflight.commands[#{index}] must be a non-empty string"
          end
          normalized = command.strip
          if normalized.empty?
            raise ConfigurationError, "agent workspace publish_policy commit_preflight.commands[#{index}] must be a non-empty string"
          end
          normalized
        end.freeze
      end

      def commit_preflight_record(record)
        if record.key?("commit_hook_policy")
          raise ConfigurationError, "unsupported agent workspace publish_policy commit_hook_policy; use commit_preflight.native_git_hooks"
        end
        commit_preflight = record["commit_preflight"]
        return {} if commit_preflight.nil?
        unless commit_preflight.respond_to?(:transform_keys)
          raise ConfigurationError, "agent workspace publish_policy commit_preflight must be a mapping"
        end

        preflight_record = commit_preflight.transform_keys(&:to_s)
        unsupported_keys = preflight_record.keys - %w[native_git_hooks commands]
        unless unsupported_keys.empty?
          raise ConfigurationError, "unsupported agent workspace publish_policy commit_preflight.#{unsupported_keys.first}"
        end
        preflight_record
      end

      def required_string(value, name)
        string = value.to_s
        raise ConfigurationError, "#{name} must be provided" if string.empty?

        string
      end
    end
  end
end
