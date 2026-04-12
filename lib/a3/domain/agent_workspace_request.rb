# frozen_string_literal: true

module A3
  module Domain
    class AgentWorkspaceRequest
      MODES = %i[agent_materialized].freeze
      WORKSPACE_KINDS = %i[ticket_workspace runtime_workspace].freeze
      FRESHNESS_POLICIES = %i[reuse_if_clean_and_ref_matches force_fresh].freeze
      CLEANUP_POLICIES = %i[retain_until_a3_cleanup cleanup_after_job].freeze
      PUBLISH_POLICY_MODES = %w[commit_declared_changes_on_success].freeze

      attr_reader :mode, :workspace_kind, :workspace_id, :freshness_policy, :cleanup_policy, :publish_policy, :slots

      def initialize(mode:, workspace_kind:, workspace_id:, freshness_policy:, cleanup_policy:, slots:, publish_policy: nil)
        @mode = normalize_symbol(mode, "mode", MODES)
        @workspace_kind = normalize_symbol(workspace_kind, "workspace_kind", WORKSPACE_KINDS)
        @workspace_id = required_string(workspace_id, "workspace_id")
        @freshness_policy = normalize_symbol(freshness_policy, "freshness_policy", FRESHNESS_POLICIES)
        @cleanup_policy = normalize_symbol(cleanup_policy, "cleanup_policy", CLEANUP_POLICIES)
        @publish_policy = normalize_publish_policy(publish_policy)
        @slots = normalize_slots(slots)
        validate_slots!
        freeze
      end

      def self.from_request_form(record)
        new(
          mode: record.fetch("mode"),
          workspace_kind: record.fetch("workspace_kind"),
          workspace_id: record.fetch("workspace_id"),
          freshness_policy: record.fetch("freshness_policy"),
          cleanup_policy: record.fetch("cleanup_policy"),
          publish_policy: record["publish_policy"],
          slots: record.fetch("slots")
        )
      end

      def request_form
        form = {
          "mode" => mode.to_s,
          "workspace_kind" => workspace_kind.to_s,
          "workspace_id" => workspace_id,
          "freshness_policy" => freshness_policy.to_s,
          "cleanup_policy" => cleanup_policy.to_s,
          "slots" => slots
        }
        form["publish_policy"] = publish_policy if publish_policy
        form
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.request_form == request_form
      end
      alias eql? ==

      private

      def normalize_symbol(value, name, allowed)
        normalized = value.to_sym
        return normalized if allowed.include?(normalized)

        raise ConfigurationError, "unsupported agent workspace #{name}: #{value.inspect}"
      end

      def required_string(value, name)
        string = value.to_s
        raise ConfigurationError, "#{name} must be provided" if string.empty?

        string
      end

      def normalize_slots(value)
        value.each_with_object({}) do |(slot, descriptor), normalized|
          slot_name = required_string(slot, "slot name")
          normalized[slot_name] = normalize_slot_descriptor(descriptor)
        end.freeze
      end

      def normalize_publish_policy(value)
        return nil if value.nil?

        record = value.transform_keys(&:to_s)
        mode = required_string(record.fetch("mode"), "publish policy mode")
        raise ConfigurationError, "unsupported agent workspace publish_policy mode: #{mode}" unless PUBLISH_POLICY_MODES.include?(mode)

        {
          "mode" => mode,
          "commit_message" => required_string(record.fetch("commit_message"), "publish policy commit_message")
        }.freeze
      end

      def normalize_slot_descriptor(descriptor)
        record = descriptor.transform_keys(&:to_s)
        {
          "source" => normalize_source(record.fetch("source")),
          "ref" => required_string(record.fetch("ref"), "slot ref"),
          "checkout" => required_string(record.fetch("checkout"), "slot checkout"),
          "access" => required_string(record.fetch("access"), "slot access"),
          "sync_class" => required_string(record.fetch("sync_class"), "slot sync_class"),
          "ownership" => required_string(record.fetch("ownership"), "slot ownership"),
          "required" => normalize_required(record.fetch("required"))
        }.freeze
      end

      def normalize_source(source)
        record = source.transform_keys(&:to_s)
        {
          "kind" => required_string(record.fetch("kind"), "source kind"),
          "alias" => required_string(record.fetch("alias"), "source alias")
        }.freeze
      end

      def normalize_required(value)
        return value if [true, false].include?(value)

        raise ConfigurationError, "slot required must be true or false"
      end

      def validate_slots!
        raise ConfigurationError, "agent workspace slots must not be empty" if slots.empty?

        slots.each do |slot_name, descriptor|
          source = descriptor.fetch("source")
          raise ConfigurationError, "unsupported source kind for #{slot_name}: #{source.fetch('kind')}" unless source.fetch("kind") == "local_git"
          raise ConfigurationError, "unsupported checkout for #{slot_name}: #{descriptor.fetch('checkout')}" unless descriptor.fetch("checkout") == "worktree_branch"
          raise ConfigurationError, "unsupported branch ref for #{slot_name}: #{descriptor.fetch('ref')}" unless descriptor.fetch("ref").start_with?("refs/heads/")
          raise ConfigurationError, "unsupported access for #{slot_name}: #{descriptor.fetch('access')}" unless %w[read_write read_only].include?(descriptor.fetch("access"))
          raise ConfigurationError, "unsupported sync_class for #{slot_name}: #{descriptor.fetch('sync_class')}" unless %w[eager lazy_but_guaranteed].include?(descriptor.fetch("sync_class"))
          raise ConfigurationError, "unsupported ownership for #{slot_name}: #{descriptor.fetch('ownership')}" unless %w[edit_target support].include?(descriptor.fetch("ownership"))
        end
      end
    end
  end
end
