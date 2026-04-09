# frozen_string_literal: true

module A3
  module Domain
    class MergeSource
      attr_reader :source_ref

      def initialize(source_ref:)
        @source_ref = source_ref
        freeze
      end

      def ==(other)
        other.is_a?(self.class) && other.source_ref == source_ref
      end
      alias eql? ==
    end
  end
end
