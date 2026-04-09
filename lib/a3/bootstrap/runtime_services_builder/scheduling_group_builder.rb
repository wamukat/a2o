# frozen_string_literal: true

module A3
  module Bootstrap
    class RuntimeServicesBuilder
      class SchedulingGroupBuilder
        def self.build(repositories:, support_group:, external_task_source: A3::Infra::NullExternalTaskSource.new)
          sync_external_tasks = A3::Application::SyncExternalTasks.new(
            task_repository: repositories.fetch(:task_repository),
            external_task_source: external_task_source
          )
          plan_next_runnable_task = A3::Application::PlanNextRunnableTask.new(
            task_repository: repositories.fetch(:task_repository),
            sync_external_tasks: sync_external_tasks
          )
          start_run = A3::Application::StartRun.new(
            start_phase: support_group.fetch(:start_phase),
            register_started_run: support_group.fetch(:register_started_run),
            task_repository: repositories.fetch(:task_repository),
            prepare_workspace: support_group.fetch(:prepare_workspace)
          )
          schedule_next_run = A3::Application::ScheduleNextRun.new(
            plan_next_runnable_task: plan_next_runnable_task,
            start_run: start_run,
            build_scope_snapshot: support_group.fetch(:build_scope_snapshot),
            build_artifact_owner: support_group.fetch(:build_artifact_owner),
            integration_ref_readiness_checker: support_group.fetch(:integration_ref_readiness_checker)
          )

          {
            sync_external_tasks: sync_external_tasks,
            plan_next_runnable_task: plan_next_runnable_task,
            start_run: start_run,
            schedule_next_run: schedule_next_run
          }
        end
      end
    end
  end
end
