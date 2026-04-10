# frozen_string_literal: true

module A3
  module Bootstrap
    class ContainerBuilder
      class SharedServicesBuilder
        def self.build(context:)
          new(context: context).build
        end

        def initialize(context:)
          @context = context
        end

        def build
          {
            plan_persisted_rerun: plan_persisted_rerun,
            execute_next_runnable_task: execute_next_runnable_task,
            cleanup_terminal_task_workspaces: cleanup_terminal_task_workspaces,
            quarantine_terminal_task_workspaces: quarantine_terminal_task_workspaces,
            scheduler_cycle_journal: scheduler_cycle_journal,
            execute_until_idle: execute_until_idle
          }.freeze
        end

        private

        def plan_persisted_rerun
          @plan_persisted_rerun ||= A3::Application::PlanPersistedRerun.new(
            task_repository: @context.task_repository,
            run_repository: @context.run_repository,
            plan_rerun: @context.plan_rerun,
            build_scope_snapshot: @context.build_scope_snapshot,
            build_artifact_owner: @context.build_artifact_owner
          )
        end

        def execute_next_runnable_task
          @execute_next_runnable_task ||= A3::Application::ExecuteNextRunnableTask.new(
            schedule_next_run: @context.schedule_next_run,
            run_worker_phase: @context.run_worker_phase,
            run_verification: @context.run_verification,
            run_merge: @context.run_merge
          )
        end

        def execute_until_idle
          @execute_until_idle ||= A3::Application::ExecuteUntilIdle.new(
            execute_next_runnable_task: execute_next_runnable_task,
            cycle_journal: scheduler_cycle_journal,
            quarantine_terminal_task_workspaces: quarantine_terminal_task_workspaces,
            cleanup_terminal_task_workspaces: cleanup_terminal_task_workspaces
          )
        end

        def scheduler_cycle_journal
          @scheduler_cycle_journal ||= A3::Application::SchedulerCycleJournal.new(
            scheduler_state_repository: @context.scheduler_state_repository,
            scheduler_cycle_repository: @context.scheduler_cycle_repository
          )
        end

        def quarantine_terminal_task_workspaces
          @quarantine_terminal_task_workspaces ||= A3::Application::QuarantineTerminalTaskWorkspaces.new(
            task_repository: @context.task_repository,
            provisioner: @context.workspace_provisioner
          )
        end

        def cleanup_terminal_task_workspaces
          @cleanup_terminal_task_workspaces ||= A3::Application::CleanupTerminalTaskWorkspaces.new(
            task_repository: @context.task_repository,
            provisioner: @context.workspace_provisioner
          )
        end
      end
    end
  end
end
