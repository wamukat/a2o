# frozen_string_literal: true

require "fileutils"
require "shellwords"
require "a3/infra/workspace_trace_logger"

module A3
  module Infra
    class LocalWorkerGateway
      def initialize(command_runner: A3::Infra::LocalCommandRunner.new, worker_command: nil, worker_command_args: [], worker_protocol: A3::Infra::WorkerProtocol.new)
        @command_runner = command_runner
        @worker_command = worker_command
        @worker_command_args = Array(worker_command_args).freeze
        @worker_protocol = worker_protocol
      end

      def run(skill:, workspace:, task:, run:, phase_runtime:, task_packet:, prior_review_feedback: nil)
        result_path = @worker_protocol.result_path(workspace)
        FileUtils.rm_f(result_path)
        A3::Infra::WorkspaceTraceLogger.log(
          workspace_root: workspace.root_path,
          event: "worker_gateway.request.start",
          payload: {
            "task_ref" => task.ref,
            "run_ref" => run.ref,
            "phase" => run.phase.to_s,
            "skill" => skill
          }
        )
        request_form = @worker_protocol.write_request(
          skill: skill,
          workspace: workspace,
          task: task,
          run: run,
          phase_runtime: phase_runtime,
          task_packet: task_packet,
          prior_review_feedback: prior_review_feedback
        )
        command = worker_command_for(skill)
        A3::Infra::WorkspaceTraceLogger.log(
          workspace_root: workspace.root_path,
          event: "worker_gateway.command.start",
          payload: {
            "task_ref" => task.ref,
            "run_ref" => run.ref,
            "phase" => run.phase.to_s,
            "command" => command
          }
        )
        prompt_metadata = @worker_protocol.project_prompt_metadata(request_form)
        @command_runner.run(
          [command],
          workspace: workspace,
          env: @worker_protocol.env_for(workspace)
        ).then do |execution_result|
          A3::Infra::WorkspaceTraceLogger.log(
            workspace_root: workspace.root_path,
            event: "worker_gateway.command.finish",
            payload: {
              "task_ref" => task.ref,
              "run_ref" => run.ref,
              "phase" => run.phase.to_s,
              "success" => execution_result.success,
              "summary" => execution_result.summary,
              "failing_command" => execution_result.failing_command,
              "observed_state" => execution_result.observed_state
            }
          )
          worker_response = @worker_protocol.load_result(result_path)
          if worker_response.is_a?(A3::Application::ExecutionResult)
            with_project_prompt_metadata(worker_response, prompt_metadata)
          else
            execution = @worker_protocol.build_execution_result(
              worker_response,
              workspace: workspace,
              expected_task_ref: task.ref,
              expected_run_ref: run.ref,
              expected_phase: run.phase,
              expected_task_kind: task.kind
            ) || execution_result
            with_project_prompt_metadata(execution, prompt_metadata)
          end
        end
      end

      private

      def worker_command_for(skill)
        return skill unless @worker_command

        Shellwords.join([@worker_command, *@worker_command_args])
      end

      def with_project_prompt_metadata(execution, metadata)
        return execution unless metadata

        execution.with_diagnostics(execution.diagnostics.merge("project_prompt" => metadata))
      end
    end
  end
end
