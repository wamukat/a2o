# frozen_string_literal: true

module A3
  module Application
    class CleanupTerminalTaskWorkspaces
      CleanedWorkspace = Struct.new(:task_ref, :status, :cleaned_paths, keyword_init: true)
      Result = Struct.new(:cleaned, :dry_run, :statuses, :scopes, keyword_init: true)

      DEFAULT_STATUSES = [:done].freeze
      DEFAULT_SCOPES = [:ticket_workspace, :runtime_workspace].freeze

      def initialize(task_repository:, provisioner:)
        @task_repository = task_repository
        @provisioner = provisioner
      end

      def call(statuses: DEFAULT_STATUSES, scopes: DEFAULT_SCOPES, dry_run: false)
        selected_statuses = Array(statuses).map(&:to_sym).freeze
        selected_scopes = Array(scopes).map(&:to_sym).freeze

        cleaned = @task_repository.all
          .select { |task| cleanup_candidate?(task, selected_statuses) }
          .map do |task|
            cleaned_paths = @provisioner.cleanup_task(
              task_ref: task.ref,
              scopes: selected_scopes,
              dry_run: dry_run
            )
            next if cleaned_paths.empty?

            CleanedWorkspace.new(
              task_ref: task.ref,
              status: task.status,
              cleaned_paths: cleaned_paths.freeze
            )
          end
          .compact

        Result.new(
          cleaned: cleaned.freeze,
          dry_run: dry_run,
          statuses: selected_statuses,
          scopes: selected_scopes
        )
      end

      private

      def cleanup_candidate?(task, statuses)
        task.current_run_ref.nil? &&
          terminal_status?(task) &&
          statuses.include?(task.status)
      end

      def terminal_status?(task)
        %i[done blocked].include?(task.status)
      end
    end
  end
end
