# frozen_string_literal: true

module A3
  module Domain
    class SharedRefLockConflict < ConfigurationError
      attr_reader :holder_ref

      def initialize(message, holder_ref: nil)
        @holder_ref = holder_ref
        super(message)
      end
    end
  end
end
