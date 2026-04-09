# frozen_string_literal: true

module A3
  module Bootstrap
    class ContainerBuilder
      class SchedulerGroupBuilder
        def self.build(context:, execute_until_idle:)
          {
            show_scheduler_state: A3::Application::ShowSchedulerState.new(
              scheduler_state_repository: context.scheduler_state_repository
            ),
            show_state: A3::Application::ShowState.new(
              task_repository: context.task_repository,
              run_repository: context.run_repository,
              scheduler_state_repository: context.scheduler_state_repository,
              scheduler_cycle_repository: context.scheduler_cycle_repository,
              storage_dir: context.storage_dir.to_s
            ),
            repair_runs: A3::Application::RepairRuns.new(
              task_repository: context.task_repository,
              run_repository: context.run_repository,
              storage_dir: context.storage_dir.to_s
            ),
            show_scheduler_history: A3::Application::ShowSchedulerHistory.new(
              scheduler_cycle_repository: context.scheduler_cycle_repository
            ),
            pause_scheduler: A3::Application::PauseScheduler.new(
              scheduler_state_repository: context.scheduler_state_repository
            ),
            resume_scheduler: A3::Application::ResumeScheduler.new(
              scheduler_state_repository: context.scheduler_state_repository
            ),
            execute_until_idle: execute_until_idle
          }
        end
      end
    end
  end
end
