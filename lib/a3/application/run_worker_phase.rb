# frozen_string_literal: true

require_relative "phase_execution_flow"
require_relative "phase_execution_strategy"

module A3
  module Application
    class RunWorkerPhase
      Result = Struct.new(:task, :run, :workspace, keyword_init: true)

      def initialize(task_repository:, run_repository:, register_completed_run:, prepare_workspace:, worker_gateway:, task_packet_builder:, workspace_change_publisher: A3::Infra::LocalWorkspaceChangePublisher.new, blocked_diagnosis_factory: A3::Domain::BlockedDiagnosisFactory.new)
        @strategy = A3::Application::WorkerPhaseExecutionStrategy.new(
          worker_gateway: worker_gateway,
          task_packet_builder: task_packet_builder,
          workspace_change_publisher: workspace_change_publisher
        )
        @flow = A3::Application::PhaseExecutionFlow.new(
          task_repository: task_repository,
          run_repository: run_repository,
          register_completed_run: register_completed_run,
          prepare_workspace: prepare_workspace,
          blocked_diagnosis_factory: blocked_diagnosis_factory
        )
      end

      def call(task_ref:, run_ref:, project_context:)
        @flow.call(
          task_ref: task_ref,
          run_ref: run_ref,
          project_context: project_context,
          strategy: @strategy
        )
      end
    end
  end
end
