# frozen_string_literal: true

require "securerandom"

module A3
  module Infra
    class AgentCommandRunner
      def initialize(control_plane_client:, runtime_profile:, shared_workspace_mode:, timeout_seconds: 1800, poll_interval_seconds: 1.0, job_id_generator: -> { SecureRandom.uuid }, sleeper: ->(seconds) { sleep(seconds) }, monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, workspace_request_builder: nil, env: {})
        @control_plane_client = control_plane_client
        @runtime_profile = runtime_profile.to_s
        @shared_workspace_mode = shared_workspace_mode.to_s
        @timeout_seconds = Integer(timeout_seconds)
        @poll_interval_seconds = Float(poll_interval_seconds)
        @job_id_generator = job_id_generator
        @sleeper = sleeper
        @monotonic_clock = monotonic_clock
        @workspace_request_builder = workspace_request_builder
        @env = env.transform_keys(&:to_s).transform_values(&:to_s).freeze
      end

      def agent_owned_workspace?
        @shared_workspace_mode == "agent-materialized"
      end

      def run(commands, workspace:, env: {}, task: nil, run: nil, **)
        return invalid_configuration_result("agent command runner requires task and run context") unless task && run
        return invalid_configuration_result("agent-materialized command runner requires workspace_request_builder") if @shared_workspace_mode == "agent-materialized" && !@workspace_request_builder
        return unsupported_workspace_result unless %w[same-path agent-materialized].include?(@shared_workspace_mode)

        summaries = []
        Array(commands).each do |command|
          request = build_job_request(command: command, workspace: workspace, env: env, task: task, run: run)
          record = enqueue(request)
          return record if record.is_a?(A3::Application::ExecutionResult)

          completed = wait_for_completion(request.job_id)
          return completed if completed.is_a?(A3::Application::ExecutionResult)

          result = completed.result
          return failed_command_result(command: command, result: result) unless result.succeeded?

          summaries << "#{command} ok"
        end

        A3::Application::ExecutionResult.new(success: true, summary: summaries.join("; "))
      end

      private

      def build_job_request(command:, workspace:, env:, task:, run:)
        A3::Domain::AgentJobRequest.new(
          job_id: job_id_for(run),
          task_ref: task.ref,
          phase: run.phase,
          runtime_profile: @runtime_profile,
          source_descriptor: run.source_descriptor,
          workspace_request: workspace_request_for(workspace: workspace, task: task, run: run),
          working_dir: workspace.root_path.to_s,
          command: "sh",
          args: ["-lc", command.to_s],
          env: default_env.merge(@env).merge(env),
          timeout_seconds: @timeout_seconds,
          artifact_rules: []
        )
      end

      def workspace_request_for(workspace:, task:, run:)
        return nil if @shared_workspace_mode == "same-path"

        @workspace_request_builder.call(workspace: workspace, task: task, run: run)
      end

      def enqueue(request)
        @control_plane_client.enqueue(request)
      rescue StandardError => e
        A3::Application::ExecutionResult.new(
          success: false,
          summary: "agent verification job enqueue failed",
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
          summary: "agent verification job wait timed out",
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
          summary: "agent verification job fetch failed",
          failing_command: "agent_job_fetch",
          observed_state: "agent_job_fetch_failed",
          diagnostics: {
            "job_id" => job_id,
            "control_plane_url" => control_plane_url,
            "error" => "#{e.class}: #{e.message}"
          }
        )
      end

      def failed_command_result(command:, result:)
        A3::Application::ExecutionResult.new(
          success: false,
          summary: "#{command} failed",
          failing_command: command.to_s,
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

      def unsupported_workspace_result
        A3::Application::ExecutionResult.new(
          success: false,
          summary: "agent command runner shared workspace mode is not supported",
          failing_command: "agent_command_runner_config",
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
          failing_command: "agent_command_runner_config",
          observed_state: "agent_command_runner_invalid_config"
        )
      end

      def default_env
        {
          "A3_ROOT_DIR" => ENV.fetch("A3_ROOT_DIR", Dir.pwd)
        }
      end

      def job_id_for(run)
        "command-#{safe_id(run.ref)}-#{safe_id(run.phase)}-#{safe_id(@job_id_generator.call)}"
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
