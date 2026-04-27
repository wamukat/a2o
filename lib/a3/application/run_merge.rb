# frozen_string_literal: true

require_relative "phase_execution_flow"
require_relative "phase_execution_strategy"

module A3
  module Application
    class RunMerge
      Result = Struct.new(:task, :run, :merge_plan, :workspace, keyword_init: true)

      def initialize(task_repository:, run_repository:, register_completed_run:, build_merge_plan:, merge_runner:, prepare_workspace:, command_runner: A3::Infra::LocalCommandRunner.new, blocked_diagnosis_factory: A3::Domain::BlockedDiagnosisFactory.new)
        @build_merge_plan = build_merge_plan
        @merge_runner = merge_runner
        @flow = A3::Application::PhaseExecutionFlow.new(
          task_repository: task_repository,
          run_repository: run_repository,
          register_completed_run: register_completed_run,
          prepare_workspace: prepare_workspace,
          blocked_diagnosis_factory: blocked_diagnosis_factory,
          notification_hook_runner: A3::Application::RunNotificationHooks.new(command_runner: command_runner)
        )
      end

      def call(task_ref:, run_ref:, project_context:)
        build_result = @build_merge_plan.call(task_ref: task_ref, run_ref: run_ref, project_context: project_context)
        strategy = merge_strategy(build_result.merge_plan)
        result = @flow.call(
          task_ref: task_ref,
          run_ref: run_ref,
          project_context: project_context,
          task: build_result.task,
          run: build_result.run,
          strategy: strategy
        )

        Result.new(task: result.task, run: result.run, merge_plan: build_result.merge_plan, workspace: result.workspace)
      end

      private

      def merge_strategy(merge_plan)
        A3::Application::MergeExecutionStrategy.new(merge_runner: @merge_runner, merge_plan: merge_plan)
      end
    end
  end
end
