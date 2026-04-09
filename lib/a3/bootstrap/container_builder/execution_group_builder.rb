# frozen_string_literal: true

module A3
  module Bootstrap
    class ContainerBuilder
      class ExecutionGroupBuilder
        def self.build(context:, execute_next_runnable_task:, execute_until_idle:, quarantine_terminal_task_workspaces:, cleanup_terminal_task_workspaces:)
          {
            prepare_workspace: context.prepare_workspace,
            plan_next_runnable_task: context.plan_next_runnable_task,
            schedule_next_run: context.schedule_next_run,
            build_merge_plan: context.build_merge_plan,
            run_verification: context.run_verification,
            run_worker_phase: context.run_worker_phase,
            run_merge: context.run_merge,
            register_completed_run: context.register_completed_run,
            start_run: context.start_run,
            execute_next_runnable_task: execute_next_runnable_task,
            execute_until_idle: execute_until_idle,
            cleanup_terminal_task_workspaces: cleanup_terminal_task_workspaces,
            quarantine_terminal_task_workspaces: quarantine_terminal_task_workspaces
          }
        end
      end
    end
  end
end
