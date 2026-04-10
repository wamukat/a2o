# frozen_string_literal: true

module A3
  module Application
    class SchedulerCleanupRunner
      DEFAULT_STATUSES = %i[done blocked].freeze
      DEFAULT_SCOPES = %i[ticket_workspace runtime_workspace].freeze

      def initialize(cleanup_terminal_task_workspaces:)
        @cleanup_terminal_task_workspaces = cleanup_terminal_task_workspaces
      end

      def call
        @cleanup_terminal_task_workspaces.call(
          statuses: DEFAULT_STATUSES,
          scopes: DEFAULT_SCOPES,
          dry_run: false
        ).cleaned.size
      end
    end
  end
end
