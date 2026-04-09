# frozen_string_literal: true

module A3
  module Domain
    class IntegrationTarget
      attr_reader :target_ref, :bootstrap_ref

      def initialize(target_ref:, bootstrap_ref: nil)
        @target_ref = target_ref
        @bootstrap_ref = bootstrap_ref
        freeze
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.target_ref == target_ref &&
          other.bootstrap_ref == bootstrap_ref
      end
      alias eql? ==
    end
  end
end
