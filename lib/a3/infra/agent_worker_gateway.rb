# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "a3/infra/workspace_trace_logger"

module A3
  module Infra
    class AgentWorkerGateway
      def initialize(control_plane_client:, worker_command:, worker_command_args: [], runtime_profile:, shared_workspace_mode:, timeout_seconds: 1800, poll_interval_seconds: 1.0, job_id_generator: -> { SecureRandom.uuid }, sleeper: ->(seconds) { sleep(seconds) }, monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, worker_protocol: A3::Infra::WorkerProtocol.new, workspace_request_builder: nil)
        @control_plane_client = control_plane_client
        @worker_command = worker_command.to_s
        @worker_command_args = Array(worker_command_args).map(&:to_s).freeze
        @runtime_profile = runtime_profile.to_s
        @shared_workspace_mode = shared_workspace_mode.to_s
        @timeout_seconds = Integer(timeout_seconds)
        @poll_interval_seconds = Float(poll_interval_seconds)
        @job_id_generator = job_id_generator
        @sleeper = sleeper
        @monotonic_clock = monotonic_clock
        @worker_protocol = worker_protocol
        @workspace_request_builder = workspace_request_builder
      end

      def run(skill:, workspace:, task:, run:, phase_runtime:, task_packet:)
        return invalid_configuration_result("worker_command must be provided") if @worker_command.empty?
        return run_same_path(skill: skill, workspace: workspace, task: task, run: run, phase_runtime: phase_runtime, task_packet: task_packet) if @shared_workspace_mode == "same-path"
        return run_agent_materialized(skill: skill, workspace: workspace, task: task, run: run, phase_runtime: phase_runtime, task_packet: task_packet) if @shared_workspace_mode == "agent-materialized"

        unsupported_workspace_result
      end

      private

      def run_same_path(skill:, workspace:, task:, run:, phase_runtime:, task_packet:)
        result_path = @worker_protocol.result_path(workspace)
        FileUtils.rm_f(result_path)
        log_request_start(workspace: workspace, task: task, run: run, skill: skill)
        @worker_protocol.write_request(
          skill: skill,
          workspace: workspace,
          task: task,
          run: run,
          phase_runtime: phase_runtime,
          task_packet: task_packet
        )

        request = build_job_request(workspace: workspace, task: task, run: run)
        record = enqueue(request)
        return record if record.is_a?(A3::Application::ExecutionResult)

        completed = wait_for_completion(request.job_id)
        return completed if completed.is_a?(A3::Application::ExecutionResult)

        worker_response = @worker_protocol.load_result(result_path)
        return worker_response if worker_response.is_a?(A3::Application::ExecutionResult)

        execution = @worker_protocol.build_execution_result(
          worker_response,
          workspace: workspace,
          expected_task_ref: task.ref,
          expected_run_ref: run.ref,
          expected_phase: run.phase
        )
        return execution if execution
        return agent_result_execution(completed.result) unless completed.result.succeeded?

        @worker_protocol.missing_result
      end

      def run_agent_materialized(skill:, workspace:, task:, run:, phase_runtime:, task_packet:)
        return invalid_configuration_result("workspace_request_builder must be provided for agent-materialized mode") unless @workspace_request_builder

        log_request_start(workspace: workspace, task: task, run: run, skill: skill)
        request = build_job_request(
          workspace: workspace,
          task: task,
          run: run,
          workspace_request: @workspace_request_builder.call(workspace: workspace, task: task, run: run),
          worker_protocol_request: @worker_protocol.request_form(
            skill: skill,
            workspace: workspace,
            task: task,
            run: run,
            phase_runtime: phase_runtime,
            task_packet: task_packet
          )
        )
        record = enqueue(request)
        return record if record.is_a?(A3::Application::ExecutionResult)

        completed = wait_for_completion(request.job_id)
        return completed if completed.is_a?(A3::Application::ExecutionResult)
        return agent_result_execution(completed.result) unless completed.result.succeeded?
        return materialized_implementation_changed_files_unavailable(completed.result) if run.phase.to_sym == :implementation && completed.result.worker_protocol_result&.fetch("success", nil) == true

        worker_response = completed.result.worker_protocol_result
        execution = @worker_protocol.build_execution_result(
          worker_response,
          workspace: workspace,
          expected_task_ref: task.ref,
          expected_run_ref: run.ref,
          expected_phase: run.phase
        )
        return execution if execution

        @worker_protocol.missing_result
      end

      def build_job_request(workspace:, task:, run:, workspace_request: nil, worker_protocol_request: nil)
        A3::Domain::AgentJobRequest.new(
          job_id: job_id_for(run),
          task_ref: task.ref,
          phase: run.phase,
          runtime_profile: @runtime_profile,
          source_descriptor: run.source_descriptor,
          workspace_request: workspace_request,
          worker_protocol_request: worker_protocol_request,
          working_dir: workspace.root_path.to_s,
          command: @worker_command,
          args: @worker_command_args,
          env: @worker_protocol.env_for(workspace),
          timeout_seconds: @timeout_seconds,
          artifact_rules: []
        )
      end

      def enqueue(request)
        @control_plane_client.enqueue(request)
      rescue StandardError => e
        A3::Application::ExecutionResult.new(
          success: false,
          summary: "agent job enqueue failed",
          failing_command: "agent_job_enqueue",
          observed_state: "agent_job_enqueue_failed",
          diagnostics: {
            "job_id" => request.job_id,
            "control_plane_url" => control_plane_url,
            "error" => "#{e.class}: #{e.message}"
          }
        )
      end

      def wait_for_completion(job_id)
        deadline = @monotonic_clock.call + @timeout_seconds
        last_record = nil
        loop do
          last_record = @control_plane_client.fetch(job_id)
          return last_record if last_record.state == :completed

          break if @monotonic_clock.call >= deadline

          @sleeper.call([@poll_interval_seconds, deadline - @monotonic_clock.call].min)
        end
        A3::Application::ExecutionResult.new(
          success: false,
          summary: "agent job wait timed out",
          failing_command: "agent_job_wait",
          observed_state: "agent_job_wait_timeout",
          diagnostics: {
            "job_id" => job_id,
            "last_state" => last_record&.state&.to_s,
            "control_plane_url" => control_plane_url
          }
        )
      rescue StandardError => e
        A3::Application::ExecutionResult.new(
          success: false,
          summary: "agent job fetch failed",
          failing_command: "agent_job_fetch",
          observed_state: "agent_job_fetch_failed",
          diagnostics: {
            "job_id" => job_id,
            "control_plane_url" => control_plane_url,
            "error" => "#{e.class}: #{e.message}"
          }
        )
      end

      def agent_result_execution(result)
        A3::Application::ExecutionResult.new(
          success: false,
          summary: result.summary,
          failing_command: "agent_job",
          observed_state: result.status.to_s,
          diagnostics: {
            "agent_job_result" => result.result_form,
            "control_plane_url" => control_plane_url
          },
          response_bundle: {
            "agent_job_result" => result.result_form
          }
        )
      end

      def materialized_implementation_changed_files_unavailable(result)
        A3::Application::ExecutionResult.new(
          success: false,
          summary: "agent materialized implementation changed_files evidence is not available",
          failing_command: "agent_materialized_changed_files",
          observed_state: "agent_materialized_changed_files_unavailable",
          diagnostics: {
            "agent_job_result" => result.result_form,
            "control_plane_url" => control_plane_url
          },
          response_bundle: {
            "agent_job_result" => result.result_form
          }
        )
      end

      def unsupported_workspace_result
        A3::Application::ExecutionResult.new(
          success: false,
          summary: "agent shared workspace mode is not supported",
          failing_command: "agent_workspace",
          observed_state: "agent_workspace_unavailable",
          diagnostics: {
            "shared_workspace_mode" => @shared_workspace_mode,
            "supported_shared_workspace_modes" => %w[same-path agent-materialized]
          }
        )
      end

      def invalid_configuration_result(message)
        A3::Application::ExecutionResult.new(
          success: false,
          summary: message,
          failing_command: "agent_worker_gateway_config",
          observed_state: "agent_worker_gateway_invalid_config"
        )
      end

      def log_request_start(workspace:, task:, run:, skill:)
        A3::Infra::WorkspaceTraceLogger.log(
          workspace_root: workspace.root_path,
          event: "agent_worker_gateway.request.start",
          payload: {
            "task_ref" => task.ref,
            "run_ref" => run.ref,
            "phase" => run.phase.to_s,
            "skill" => skill,
            "runtime_profile" => @runtime_profile,
            "control_plane_url" => control_plane_url
          }
        )
      end

      def job_id_for(run)
        "worker-#{safe_id(run.ref)}-#{safe_id(run.phase)}-#{safe_id(@job_id_generator.call)}"
      end

      def safe_id(value)
        value.to_s.gsub(/[^A-Za-z0-9._:-]/, "-")
      end

      def control_plane_url
        @control_plane_client.respond_to?(:base_url) ? @control_plane_client.base_url : nil
      end
    end
  end
end
