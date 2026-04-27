# frozen_string_literal: true

require_relative "phase_execution_flow"
require_relative "phase_execution_strategy"
require_relative "collect_task_metrics"

module A3
  module Application
    class RunVerification
      Result = Struct.new(:task, :run, :workspace, keyword_init: true)

      def initialize(task_repository:, run_repository:, register_completed_run:, command_runner:, prepare_workspace:, task_packet_builder: A3::Application::BuildWorkerTaskPacket.new(external_task_source: A3::Infra::NullExternalTaskSource.new), inherited_parent_state_resolver: nil, blocked_diagnosis_factory: A3::Domain::BlockedDiagnosisFactory.new, task_metrics_repository: A3::Infra::InMemoryTaskMetricsRepository.new)
        metrics_collector = A3::Application::CollectTaskMetrics.new(
          command_runner: command_runner,
          task_metrics_repository: task_metrics_repository
        )
        @strategy = A3::Application::VerificationExecutionStrategy.new(
          command_runner: command_runner,
          task_packet_builder: task_packet_builder,
          metrics_collector: metrics_collector
        )
        @flow = A3::Application::PhaseExecutionFlow.new(
          task_repository: task_repository,
          run_repository: run_repository,
          register_completed_run: register_completed_run,
          prepare_workspace: prepare_workspace,
          inherited_parent_state_resolver: inherited_parent_state_resolver,
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
