# frozen_string_literal: true

module A3
  module Infra
    class AgentWorkspaceRequestBuilder
      def initialize(source_aliases:, freshness_policy: :reuse_if_clean_and_ref_matches, cleanup_policy: :retain_until_a3_cleanup)
        @source_aliases = source_aliases.transform_keys(&:to_sym).transform_values(&:to_s).freeze
        @freshness_policy = freshness_policy.to_sym
        @cleanup_policy = cleanup_policy.to_sym
        validate_policy!(:freshness_policy, @freshness_policy, A3::Domain::AgentWorkspaceRequest::FRESHNESS_POLICIES)
        validate_policy!(:cleanup_policy, @cleanup_policy, A3::Domain::AgentWorkspaceRequest::CLEANUP_POLICIES)
      end

      def call(workspace:, task:, run:)
        slots = required_slots_for(run).each_with_object({}) do |slot_name, request_slots|
          alias_name = @source_aliases[slot_name]
          raise A3::Domain::ConfigurationError, "missing agent source alias for #{slot_name}" if alias_name.to_s.empty?

          request_slots[slot_name] = {
            source: {
              kind: "local_git",
              alias: alias_name
            },
            ref: run.source_descriptor.ref,
            checkout: "worktree_detached",
            access: access_for(slot_name, run),
            required: true
          }
        end

        A3::Domain::AgentWorkspaceRequest.new(
          mode: :agent_materialized,
          workspace_kind: workspace.workspace_kind,
          workspace_id: workspace_id_for(task: task, run: run),
          freshness_policy: @freshness_policy,
          cleanup_policy: @cleanup_policy,
          slots: slots
        )
      end

      private

      def required_slots_for(run)
        case run.phase.to_sym
        when :implementation
          run.scope_snapshot.edit_scope
        when :review
          (run.scope_snapshot.edit_scope + run.scope_snapshot.verification_scope).uniq
        when :verification
          run.scope_snapshot.verification_scope
        else
          raise A3::Domain::ConfigurationError, "agent materialized workspace is not supported for phase #{run.phase}"
        end
      end

      def access_for(slot_name, run)
        return "read_write" if %i[implementation review].include?(run.phase.to_sym) && run.scope_snapshot.edit_scope.include?(slot_name)

        "read_only"
      end

      def workspace_id_for(task:, run:)
        if task.kind.to_sym == :child && task.parent_ref
          return "#{safe_id(task.parent_ref)}-children-#{safe_id(task.ref)}-#{safe_id(run.phase)}-#{safe_id(run.ref)}"
        end

        "#{safe_id(task.ref)}-#{safe_id(run.phase)}-#{safe_id(run.ref)}"
      end

      def safe_id(value)
        value.to_s.gsub(/[^A-Za-z0-9._:-]/, "-")
      end

      def validate_policy!(name, value, allowed)
        return if allowed.include?(value)

        raise A3::Domain::ConfigurationError, "unsupported agent workspace #{name}: #{value.inspect}"
      end
    end
  end
end
