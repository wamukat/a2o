# frozen_string_literal: true

module A3
  module Domain
    module AgentWorkspacePublishPolicy
      MODES = %w[
        commit_declared_changes_on_success
        commit_all_edit_target_changes_on_worker_success
        commit_all_edit_target_changes_on_success
      ].freeze
      COMMIT_HOOK_POLICIES = %w[bypass run].freeze
      DEFAULT_COMMIT_HOOK_POLICY = "bypass"

      module_function

      def normalize_commit_hook_policy(value)
        policy = required_string(value, "publish policy commit_hook_policy")
        return policy if COMMIT_HOOK_POLICIES.include?(policy)

        raise ConfigurationError, "unsupported agent workspace publish_policy commit_hook_policy: #{policy}"
      end

      def commit_hook_policy_from(record)
        return DEFAULT_COMMIT_HOOK_POLICY unless record.key?("commit_hook_policy")

        record["commit_hook_policy"].to_s
      end

      def required_string(value, name)
        string = value.to_s
        raise ConfigurationError, "#{name} must be provided" if string.empty?

        string
      end
    end
  end
end
