# frozen_string_literal: true

require "a3/domain/agent_workspace_request"
require "a3/domain/branch_namespace"
require "a3/domain/configuration_error"
require "a3/infra/agent_workspace_repo_policy"

module A3
  module Infra
    class AgentWorkspaceRequestBuilder
      def initialize(source_aliases:, repo_slot_policy: nil, freshness_policy: :reuse_if_clean_and_ref_matches, cleanup_policy: :retain_until_a3_cleanup, support_ref: nil, support_refs: {}, branch_namespace: A3::Domain::BranchNamespace.from_env)
        @source_aliases = source_aliases.transform_keys(&:to_sym).transform_values(&:to_s).freeze
        @branch_namespace = A3::Domain::BranchNamespace.normalize(branch_namespace)
        @repo_slot_policy = repo_slot_policy || A3::Infra::AgentWorkspaceRepoPolicy.new(available_slots: @source_aliases.keys)
        @freshness_policy = freshness_policy.to_sym
        @cleanup_policy = cleanup_policy.to_sym
        @support_refs = normalize_support_refs(support_ref: support_ref, support_refs: support_refs)
        validate_policy!(:freshness_policy, @freshness_policy, A3::Domain::AgentWorkspaceRequest::FRESHNESS_POLICIES)
        validate_policy!(:cleanup_policy, @cleanup_policy, A3::Domain::AgentWorkspaceRequest::CLEANUP_POLICIES)
      end

      def call(workspace:, task:, run:, command_intent: nil)
        validate_phase!(run.phase)
        command_intent = normalize_command_intent(command_intent)
        slots = @repo_slot_policy.resolve_slots(workspace: workspace).each_with_object({}) do |slot_name, request_slots|
          alias_name = @source_aliases[slot_name]
          raise A3::Domain::ConfigurationError, "missing agent source alias for #{slot_name}" if alias_name.to_s.empty?

          request_slots[slot_name] = {
            source: {
              kind: "local_git",
              alias: alias_name
            },
            ref: ref_for(slot_name, task, run),
            bootstrap_ref: bootstrap_ref_for(slot_name, task, run),
            bootstrap_base_ref: bootstrap_base_ref_for(slot_name, task, run),
            checkout: "worktree_branch",
            access: access_for(slot_name, run, command_intent),
            sync_class: sync_class_for(slot_name, run),
            ownership: ownership_for(slot_name, run),
            required: true
          }.compact
        end

        A3::Domain::AgentWorkspaceRequest.new(
          mode: :agent_materialized,
          workspace_kind: workspace.workspace_kind,
          workspace_id: workspace_id_for(task: task, run: run),
          freshness_policy: @freshness_policy,
          topology: topology_for(task: task, workspace: workspace),
          cleanup_policy: @cleanup_policy,
          publish_policy: publish_policy_for(task: task, run: run, command_intent: command_intent),
          slots: slots
        )
      end

      private

      def validate_phase!(phase)
        return if %i[implementation review verification].include?(phase.to_sym)

        raise A3::Domain::ConfigurationError, "agent materialized workspace is not supported for phase #{phase}"
      end

      def access_for(slot_name, run, command_intent)
        return "read_only" if command_intent == :notification
        return "read_write" if %i[implementation review].include?(run.phase.to_sym) && run.scope_snapshot.edit_scope.include?(slot_name)
        return "read_write" if command_intent == :remediation && run.phase.to_sym == :verification && run.scope_snapshot.edit_scope.include?(slot_name)

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

      def bootstrap_ref_for(slot_name, task, run)
        if ownership_for(slot_name, run) == "edit_target"
          return parent_integration_ref_for(task) if task.kind.to_sym == :child && task.parent_ref

          return support_ref_for(slot_name) if task.kind.to_sym == :single || task.kind.to_sym == :parent
        end

        return support_ref_for(slot_name) if parent_integration_support_ref?(task)

        nil
      end

      def bootstrap_base_ref_for(slot_name, task, run)
        return support_ref_for(slot_name) if ownership_for(slot_name, run) == "edit_target" && task.kind.to_sym == :child && task.parent_ref

        nil
      end

      def parent_integration_support_ref?(task)
        task.kind.to_sym == :parent || !task.parent_ref.to_s.empty?
      end

      def parent_integration_ref_for(task)
        owner_ref = task.parent_ref || task.ref
        parts = ["refs/heads/a2o"]
        parts << @branch_namespace if @branch_namespace
        parts << "parent"
        parts << owner_ref.tr("#", "-")
        parts.join("/")
      end

      def support_ref_for(slot_name)
        return @support_refs.fetch(slot_name) if @support_refs.key?(slot_name)
        return @support_refs.fetch(:default) if @support_refs.key?(:default)

        nil
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

      def publish_policy_for(task:, run:, command_intent:)
        return nil if command_intent == :notification

        if command_intent == :remediation && run.phase.to_sym == :verification
          return {
            mode: "commit_all_edit_target_changes_on_success",
            commit_message: "A2O remediation update for #{task.ref}"
          }
        end
        return nil unless run.phase.to_sym == :implementation

        {
          mode: "commit_all_edit_target_changes_on_worker_success",
          commit_message: "A2O implementation update for #{task.ref}"
        }
      end

      def normalize_command_intent(value)
        return nil if value.nil?

        normalized = value.to_sym
        return normalized if %i[remediation metrics_collection notification].include?(normalized)

        raise A3::Domain::ConfigurationError, "unsupported agent command intent: #{value.inspect}"
      end

      def topology_for(task:, workspace:)
        return nil unless task.kind.to_sym == :child && task.parent_ref

        {
          kind: "parent_child",
          parent_ref: task.parent_ref,
          child_ref: task.ref,
          parent_workspace_id: parent_workspace_id_for(task.parent_ref),
          relative_path: File.join("children", safe_id(task.ref), workspace.workspace_kind.to_s)
        }
      end

      def parent_workspace_id_for(parent_ref)
        "#{safe_id(parent_ref)}-parent"
      end

      def workspace_id_for(task:, run:)
        return parent_workspace_id_for(task.ref) if task.kind.to_sym == :parent

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
