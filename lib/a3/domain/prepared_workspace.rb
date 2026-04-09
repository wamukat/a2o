# frozen_string_literal: true

require "pathname"

module A3
  module Domain
    class PreparedWorkspace
      attr_reader :workspace_kind, :root_path, :source_descriptor, :slot_paths

      def initialize(workspace_kind:, root_path:, source_descriptor:, slot_paths:)
        @workspace_kind = workspace_kind.to_sym
        @root_path = Pathname(root_path)
        @source_descriptor = source_descriptor
        @slot_paths = slot_paths.transform_keys(&:to_sym).transform_values { |value| Pathname(value) }.freeze
        validate_workspace_boundary!
        freeze
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.workspace_kind == workspace_kind &&
          other.root_path == root_path &&
          other.source_descriptor == source_descriptor &&
          other.slot_paths == slot_paths
      end
      alias eql? ==

      def scoped_to(root_path)
        self.class.new(
          workspace_kind: workspace_kind,
          root_path: root_path,
          source_descriptor: source_descriptor,
          slot_paths: {}
        )
      end

      private

      def validate_workspace_boundary!
        return if source_descriptor.workspace_kind == workspace_kind

        raise A3::Domain::ConfigurationError,
          "prepared workspace kind #{workspace_kind} does not match source descriptor workspace kind #{source_descriptor.workspace_kind}"
      end
    end
  end
end
