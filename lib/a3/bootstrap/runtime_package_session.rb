# frozen_string_literal: true

module A3
  module Bootstrap
    class RuntimePackageSession
      attr_reader :runtime_package

      def self.build(runtime_package:)
        new(runtime_package: runtime_package)
      end

      def initialize(runtime_package:)
        @runtime_package = runtime_package
        freeze
      end
    end
  end
end
