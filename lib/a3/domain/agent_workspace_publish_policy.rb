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
        commit_preflight = record["commit_preflight"]
        return DEFAULT_NATIVE_GIT_HOOKS if commit_preflight.nil?

        preflight_record = commit_preflight.transform_keys(&:to_s)
        return DEFAULT_NATIVE_GIT_HOOKS unless preflight_record.key?("native_git_hooks")

        preflight_record["native_git_hooks"].to_s
      end

      def required_string(value, name)
        string = value.to_s
        raise ConfigurationError, "#{name} must be provided" if string.empty?

        string
      end
    end
  end
end
