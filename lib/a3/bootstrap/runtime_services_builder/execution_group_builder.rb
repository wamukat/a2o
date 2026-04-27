# frozen_string_literal: true

module A3
  module Bootstrap
    class RuntimeServicesBuilder
      class ExecutionGroupBuilder
        def self.build(repositories:, support_group:, command_runner:, merge_runner:, worker_gateway:, external_task_source:)
          build_merge_plan = A3::Application::BuildMergePlan.new(
            task_repository: repositories.fetch(:task_repository),
            run_repository: repositories.fetch(:run_repository)
          )
          build_worker_task_packet = A3::Application::BuildWorkerTaskPacket.new(
            external_task_source: external_task_source
          )

          {
            build_merge_plan: build_merge_plan,
            run_worker_phase: A3::Application::RunWorkerPhase.new(
              task_repository: repositories.fetch(:task_repository),
              run_repository: repositories.fetch(:run_repository),
              register_completed_run: support_group.fetch(:register_completed_run),
              prepare_workspace: support_group.fetch(:prepare_workspace),
              worker_gateway: worker_gateway,
              task_packet_builder: build_worker_task_packet,
              command_runner: command_runner,
              inherited_parent_state_resolver: support_group.fetch(:inherited_parent_state_resolver)
            ),
            run_verification: A3::Application::RunVerification.new(
              task_repository: repositories.fetch(:task_repository),
              run_repository: repositories.fetch(:run_repository),
              register_completed_run: support_group.fetch(:register_completed_run),
              command_runner: command_runner,
              prepare_workspace: support_group.fetch(:prepare_workspace),
              task_packet_builder: build_worker_task_packet,
              inherited_parent_state_resolver: support_group.fetch(:inherited_parent_state_resolver),
              task_metrics_repository: repositories.fetch(:task_metrics_repository, A3::Infra::InMemoryTaskMetricsRepository.new)
            ),
            run_merge: A3::Application::RunMerge.new(
              task_repository: repositories.fetch(:task_repository),
              run_repository: repositories.fetch(:run_repository),
              register_completed_run: support_group.fetch(:register_completed_run),
              build_merge_plan: build_merge_plan,
              merge_runner: merge_runner,
              prepare_workspace: support_group.fetch(:prepare_workspace),
              command_runner: command_runner
            )
          }
        end
      end
    end
  end
end
