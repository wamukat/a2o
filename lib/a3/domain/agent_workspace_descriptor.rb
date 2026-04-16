# frozen_string_literal: true

module A3
  module Domain
    class AgentWorkspaceDescriptor
      attr_reader :workspace_kind, :runtime_profile, :workspace_id, :source_descriptor, :slot_descriptors, :topology

      def initialize(workspace_kind:, runtime_profile:, workspace_id:, source_descriptor:, slot_descriptors:, topology: nil)
        @workspace_kind = workspace_kind.to_sym
        @runtime_profile = required_string(runtime_profile, "runtime_profile")
        @workspace_id = required_string(workspace_id, "workspace_id")
        @source_descriptor = source_descriptor
        @topology = normalize_optional_descriptor(topology)
        @slot_descriptors = normalize_slot_descriptors(slot_descriptors)
        validate_workspace_kind!
        freeze
      end

      def self.from_persisted_form(record)
        new(
          workspace_kind: record.fetch("workspace_kind"),
          runtime_profile: record.fetch("runtime_profile"),
          workspace_id: record.fetch("workspace_id"),
          source_descriptor: SourceDescriptor.from_persisted_form(record.fetch("source_descriptor")),
          slot_descriptors: record.fetch("slot_descriptors"),
          topology: record["topology"]
        )
      end

      def persisted_form
        {
          "workspace_kind" => workspace_kind.to_s,
          "runtime_profile" => runtime_profile,
          "workspace_id" => workspace_id,
          "source_descriptor" => source_descriptor.persisted_form,
          "slot_descriptors" => slot_descriptors
        }.tap do |form|
          form["topology"] = topology if topology
        end
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.workspace_kind == workspace_kind &&
          other.runtime_profile == runtime_profile &&
          other.workspace_id == workspace_id &&
          other.source_descriptor == source_descriptor &&
          other.slot_descriptors == slot_descriptors &&
          other.topology == topology
      end
      alias eql? ==

      private

      def required_string(value, name)
        string = value.to_s
        raise ConfigurationError, "#{name} must be provided" if string.empty?

        string
      end

      def validate_workspace_kind!
        return if source_descriptor.workspace_kind == workspace_kind

        raise ConfigurationError,
          "agent workspace kind #{workspace_kind} does not match source descriptor workspace kind #{source_descriptor.workspace_kind}"
      end

      def normalize_optional_descriptor(value)
        return nil if value.nil?

        normalize_descriptor(value)
      end

      def normalize_slot_descriptors(slot_descriptors)
        slot_descriptors.each_with_object({}) do |(slot, descriptor), normalized|
          slot_name = slot.to_s
          raise ConfigurationError, "slot name must be provided" if slot_name.empty?

          normalized[slot_name] = normalize_descriptor(descriptor)
        end.freeze
      end

      def normalize_descriptor(descriptor)
        descriptor.transform_keys(&:to_s).each_with_object({}) do |(key, value), normalized|
          normalized[key] = normalize_descriptor_value(value)
        end.freeze
      end

      def normalize_descriptor_value(value)
        case value
        when Hash
          normalize_descriptor(value)
        when Array
          value.map { |item| normalize_descriptor_value(item) }.freeze
        else
          value
        end
      end
    end
  end
end
