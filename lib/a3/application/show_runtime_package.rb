# frozen_string_literal: true

module A3
  module Application
    class ShowRuntimePackage
      def initialize(runtime_package:)
        @runtime_package = runtime_package
      end

      def call
        @runtime_package
      end
    end
  end
end
