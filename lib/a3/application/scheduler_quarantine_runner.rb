# frozen_string_literal: true

module A3
  module Application
    class SchedulerQuarantineRunner
      def initialize(quarantine_terminal_task_workspaces:)
        @quarantine_terminal_task_workspaces = quarantine_terminal_task_workspaces
      end

      def call
        @quarantine_terminal_task_workspaces.call.quarantined.size
      end
    end
  end
end
