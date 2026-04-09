# frozen_string_literal: true

module A3
  module Application
    class NullQuarantineTerminalTaskWorkspaces
      def call
        A3::Application::QuarantineTerminalTaskWorkspaces::Result.new(quarantined: [])
      end
    end
  end
end
