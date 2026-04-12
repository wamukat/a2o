# frozen_string_literal: true

module A3
  module Infra
    class AgentWorkspaceRequestBuilder
      def initialize(source_aliases:, freshness_policy: :reuse_if_clean_and_ref_matches, cleanup_policy: :retain_until_a3_cleanup, support_ref: nil, support_refs: {})
        @source_aliases = source_aliases.transform_keys(&:to_sym).transform_values(&:to_s).freeze
        @repo_slots = @source_aliases.keys.sort.freeze
        @freshness_policy = freshness_policy.to_sym
        @cleanup_policy = cleanup_policy.to_sym
        @support_refs = normalize_support_refs(support_ref: support_ref, support_refs: support_refs)
        validate_policy!(:freshness_policy, @freshness_policy, A3::Domain::AgentWorkspaceRequest::FRESHNESS_POLICIES)
        validate_policy!(:cleanup_policy, @cleanup_policy, A3::Domain::AgentWorkspaceRequest::CLEANUP_POLICIES)
      end

      def call(workspace:, task:, run:)
        validate_phase!(run.phase)
        slots = @repo_slots.each_with_object({}) do |slot_name, request_slots|
          alias_name = @source_aliases[slot_name]
          raise A3::Domain::ConfigurationError, "missing agent source alias for #{slot_name}" if alias_name.to_s.empty?

          request_slots[slot_name] = {
            source: {
              kind: "local_git",
              alias: alias_name
            },
            ref: ref_for(slot_name, task, run),
            checkout: "worktree_branch",
            access: access_for(slot_name, run),
            sync_class: sync_class_for(slot_name, run),
            ownership: ownership_for(slot_name, run),
            required: true
          }
        end

        A3::Domain::AgentWorkspaceRequest.new(
          mode: :agent_materialized,
          workspace_kind: workspace.workspace_kind,
          workspace_id: workspace_id_for(task: task, run: run),
          freshness_policy: @freshness_policy,
          cleanup_policy: @cleanup_policy,
          publish_policy: publish_policy_for(task: task, run: run),
          slots: slots
        )
      end

      private

      def validate_phase!(phase)
        return if %i[implementation review verification].include?(phase.to_sym)

        raise A3::Domain::ConfigurationError, "agent materialized workspace is not supported for phase #{phase}"
      end

      def access_for(slot_name, run)
        return "read_write" if %i[implementation review].include?(run.phase.to_sym) && run.scope_snapshot.edit_scope.include?(slot_name)

        "read_only"
      end

      def sync_class_for(slot_name, run)
        run.scope_snapshot.edit_scope.include?(slot_name) ? "eager" : "lazy_but_guaranteed"
      end

      def ownership_for(slot_name, run)
        run.scope_snapshot.edit_scope.include?(slot_name) ? "edit_target" : "support"
      end

      def ref_for(slot_name, task, run)
        return run.source_descriptor.ref if ownership_for(slot_name, run) == "edit_target"
        return parent_integration_ref_for(task) if parent_integration_support_ref?(task)
        return @support_refs.fetch(slot_name) if @support_refs.key?(slot_name)
        return @support_refs.fetch(:default) if @support_refs.key?(:default)

        raise A3::Domain::ConfigurationError, "agent support slot #{slot_name} requires --agent-support-ref"
      end

      def parent_integration_support_ref?(task)
        task.kind.to_sym == :parent || !task.parent_ref.to_s.empty?
      end

      def parent_integration_ref_for(task)
        owner_ref = task.parent_ref || task.ref
        "refs/heads/a3/parent/#{owner_ref.tr('#', '-')}"
      end

      def normalize_support_refs(support_ref:, support_refs:)
        normalized = support_refs.to_h.each_with_object({}) do |(slot, ref), refs|
          key = slot.to_s == "*" ? :default : slot.to_sym
          value = ref.to_s.strip
          refs[key] = value unless value.empty?
        end
        default_ref = support_ref.to_s.strip
        normalized[:default] = default_ref unless default_ref.empty?
        normalized.freeze
      end

      def publish_policy_for(task:, run:)
        return nil unless run.phase.to_sym == :implementation

        {
          mode: "commit_declared_changes_on_success",
          commit_message: "A3 implementation update for #{task.ref}"
        }
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
