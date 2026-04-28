# frozen_string_literal: true

require_relative "phase_execution_flow"
require_relative "phase_execution_strategy"

module A3
  module Application
    class RunWorkerPhase
      Result = Struct.new(:task, :run, :workspace, keyword_init: true)

      def initialize(task_repository:, run_repository:, register_completed_run:, prepare_workspace:, worker_gateway:, task_packet_builder:, command_runner: A3::Infra::LocalCommandRunner.new, inherited_parent_state_resolver: nil, workspace_change_publisher: A3::Infra::DisabledWorkspaceChangePublisher.new, blocked_diagnosis_factory: A3::Domain::BlockedDiagnosisFactory.new)
        @task_repository = task_repository
        @run_repository = run_repository
        @strategy = A3::Application::WorkerPhaseExecutionStrategy.new(
          worker_gateway: worker_gateway,
          task_packet_builder: task_packet_builder,
          workspace_change_publisher: workspace_change_publisher,
          run_repository: run_repository
        )
        @flow = A3::Application::PhaseExecutionFlow.new(
          task_repository: task_repository,
          run_repository: run_repository,
          register_completed_run: register_completed_run,
          prepare_workspace: prepare_workspace,
          inherited_parent_state_resolver: inherited_parent_state_resolver,
          blocked_diagnosis_factory: blocked_diagnosis_factory,
          notification_hook_runner: A3::Application::RunNotificationHooks.new(command_runner: command_runner)
        )
      end

      def call(task_ref:, run_ref:, project_context:)
        task = @task_repository.fetch(task_ref)
        run = @run_repository.fetch(run_ref)
        phase_name = run.phase.to_sym
        raise A3::Domain::InvalidPhaseError, "Unsupported phase #{phase_name} for #{task.kind}" unless task.supports_phase?(phase_name)

        @flow.call(
          task_ref: task_ref,
          run_ref: run_ref,
          project_context: project_context,
          strategy: @strategy,
          task: task,
          run: run
        )
      end
    end
  end
end
