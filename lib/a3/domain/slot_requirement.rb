# frozen_string_literal: true

module A3
  module Domain
    class SlotRequirement
      attr_reader :repo_slot, :sync_class

      def initialize(repo_slot:, sync_class:)
        @repo_slot = repo_slot.to_sym
        @sync_class = sync_class.to_sym
        freeze
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.repo_slot == repo_slot &&
          other.sync_class == sync_class
      end
      alias eql? ==
    end
  end
end
