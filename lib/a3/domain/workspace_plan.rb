# frozen_string_literal: true

module A3
  module Domain
    class WorkspacePlan
      attr_reader :workspace_kind, :source_descriptor, :slot_requirements

      def initialize(workspace_kind:, source_descriptor:, slot_requirements:)
        @workspace_kind = workspace_kind.to_sym
        @source_descriptor = source_descriptor
        @slot_requirements = slot_requirements.freeze
        freeze
      end
    end
  end
end
