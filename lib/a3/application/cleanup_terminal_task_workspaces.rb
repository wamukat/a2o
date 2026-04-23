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

        tasks = @task_repository.all
        tasks_by_ref = tasks.to_h { |task| [task.ref, task] }
        cleaned_refs = {}
        cleaned = tasks
          .select { |task| cleanup_candidate?(task, selected_statuses, selected_scopes) }
          .flat_map do |task|
            cleanup_targets_for(task, tasks_by_ref, selected_statuses, selected_scopes).map do |target|
              next if cleaned_refs[target.ref]

              cleaned_refs[target.ref] = true
              cleaned_paths = @provisioner.cleanup_task(
                task_ref: target.ref,
                scopes: selected_scopes,
                dry_run: dry_run,
                **cleanup_workspace_options_for(target)
              )
              next if cleaned_paths.empty?

              CleanedWorkspace.new(
                task_ref: target.ref,
                status: target.status,
                cleaned_paths: cleaned_paths.freeze
              )
            end
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

      def cleanup_workspace_options_for(task)
        if task.parent_ref
          {
            parent_ref: task.parent_ref,
            parent_workspace_ref: parent_workspace_ref_for(task.parent_ref)
          }
        elsif task.kind.to_sym == :parent
          { workspace_ref: parent_workspace_ref_for(task.ref) }
        else
          {}
        end
      end

      def parent_workspace_ref_for(parent_ref)
        "#{parent_ref}-parent"
      end

      def cleanup_targets_for(task, tasks_by_ref, statuses, scopes)
        targets = [task]
        if task.kind.to_sym == :parent
          terminal_children = task.child_refs.map { |child_ref| tasks_by_ref[child_ref] }.compact
            .select { |child| child.parent_ref == task.ref }
            .select { |child| cleanup_candidate?(child, statuses, scopes) }
          targets.concat(terminal_children)
        end
        targets
      end

      def cleanup_candidate?(task, statuses, scopes)
        task.current_run_ref.nil? &&
          terminal_status?(task) &&
          cleanup_safe_status?(task, scopes) &&
          statuses.include?(task.status)
      end

      def terminal_status?(task)
        %i[done blocked].include?(task.status)
      end

      def cleanup_safe_status?(task, scopes)
        return true if task.status == :done

        task.status == :blocked && scopes == [:quarantine]
      end
    end
  end
end
