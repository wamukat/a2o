# frozen_string_literal: true

require "json"
require "securerandom"
require "shellwords"

module A3
  module Infra
    class AgentCommandRunner
      def initialize(control_plane_client:, runtime_profile:, shared_workspace_mode:, timeout_seconds: 1800, poll_interval_seconds: 1.0, job_id_generator: -> { SecureRandom.uuid }, sleeper: ->(seconds) { sleep(seconds) }, monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, workspace_request_builder: nil, env: {}, agent_environment: nil)
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
        validate_root_env!(@env)
        @agent_environment = agent_environment
      end

      def agent_owned_workspace?
        @shared_workspace_mode == "agent-materialized"
      end

      def run(commands, workspace:, env: {}, task: nil, run: nil, command_intent: nil, worker_protocol_request: nil, **)
        return invalid_configuration_result("agent command runner requires task and run context") unless task && run
        return invalid_configuration_result("agent-materialized command runner requires workspace_request_builder") if @shared_workspace_mode == "agent-materialized" && !@workspace_request_builder
        return unsupported_workspace_result unless %w[same-path agent-materialized].include?(@shared_workspace_mode)

        summaries = []
        artifacts = []
        metrics_outputs = []
        Array(commands).each do |command|
          command_env = default_env(@env.merge(env)).merge(workspace_automation_env(workspace)).merge(@env).merge(env)
          expanded_command = expand_command_placeholders(command, workspace: workspace, env: command_env)
          request = build_job_request(command: expanded_command, workspace: workspace, env: command_env, task: task, run: run, command_intent: command_intent, worker_protocol_request: worker_protocol_request)
          log_agent_job_event("enqueue_start", request: request, command_intent: command_intent)
          record = enqueue(request)
          return record if record.is_a?(A3::Application::ExecutionResult)

          log_agent_job_event("enqueue_done", request: request, command_intent: command_intent, state: record.state)
          log_agent_job_event("wait_start", request: request, command_intent: command_intent)
          completed = wait_for_completion(request.job_id)
          return completed if completed.is_a?(A3::Application::ExecutionResult)

          log_agent_job_event("wait_done", request: request, command_intent: command_intent, state: completed.state, result_status: completed.result&.status)
          result = completed.result
          return failed_command_result(command: expanded_command, result: result) unless result.succeeded?

          summaries << "#{expanded_command} ok"
          artifacts.concat(agent_artifacts_from_result(result))
          metrics_outputs << metrics_output_from_result(result) if command_output_diagnostics?(command_intent)
        end

        A3::Application::ExecutionResult.new(
          success: true,
          summary: summaries.join("; "),
          diagnostics: success_diagnostics(artifacts: artifacts, metrics_outputs: metrics_outputs, command_intent: command_intent)
        )
      end

      private

      def build_job_request(command:, workspace:, env:, task:, run:, command_intent:, worker_protocol_request:)
        A3::Domain::AgentJobRequest.new(
          job_id: job_id_for(run),
          project_key: run.project_key || task.project_key,
          task_ref: task.ref,
          run_ref: run.ref,
          phase: run.phase,
          runtime_profile: @runtime_profile,
          source_descriptor: run.source_descriptor,
          workspace_request: workspace_request_for(workspace: workspace, task: task, run: run, command_intent: command_intent),
          agent_environment: @agent_environment,
          working_dir: workspace.root_path.to_s,
          command: "sh",
          args: ["-lc", command.to_s],
          env: env,
          timeout_seconds: @timeout_seconds,
          artifact_rules: [],
          worker_protocol_request: worker_protocol_request_for(command_intent: command_intent, worker_protocol_request: worker_protocol_request)
        )
      end

      def worker_protocol_request_for(command_intent:, worker_protocol_request:)
        return worker_protocol_request if worker_protocol_request
        return nil unless command_intent&.to_sym == :metrics_collection

        { "command_intent" => "metrics_collection" }
      end

      def workspace_request_for(workspace:, task:, run:, command_intent:)
        return nil if @shared_workspace_mode == "same-path"

        @workspace_request_builder.call(workspace: workspace, task: task, run: run, command_intent: command_intent)
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
        output = metrics_output_from_result(result)
        A3::Application::ExecutionResult.new(
          success: false,
          summary: "#{command} failed",
          failing_command: command.to_s,
          observed_state: result.status.to_s,
          diagnostics: {
            "agent_job_result" => result.result_form,
            "control_plane_url" => control_plane_url,
            "stdout" => output.fetch("stdout"),
            "stderr" => output.fetch("stderr")
          },
          response_bundle: {
            "agent_job_result" => result.result_form
          }
        )
      end

      def agent_artifacts_from_result(result)
        (result.log_uploads + result.artifact_uploads).map(&:persisted_form)
      end

      def success_diagnostics(artifacts:, metrics_outputs:, command_intent:)
        diagnostics = { "agent_artifacts" => artifacts }
        return diagnostics unless command_output_diagnostics?(command_intent)

        diagnostics.merge(
          "stdout" => metrics_outputs.map { |output| output.fetch("stdout") }.join,
          "stderr" => metrics_outputs.map { |output| output.fetch("stderr") }.join
        )
      end

      def command_output_diagnostics?(command_intent)
        %i[metrics_collection observer].include?(command_intent&.to_sym) || decomposition_command_intent?(command_intent)
      end

      def decomposition_command_intent?(command_intent)
        command_intent.to_s.start_with?("decomposition_")
      end

      def metrics_output_from_result(result)
        worker_diagnostics = result.worker_protocol_result&.fetch("diagnostics", nil)
        return { "stdout" => "", "stderr" => "" } unless worker_diagnostics.is_a?(Hash)

        {
          "stdout" => worker_diagnostics.fetch("stdout", "").to_s,
          "stderr" => worker_diagnostics.fetch("stderr", "").to_s
        }
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

      def default_env(overrides = {})
        if ENV.key?("A3_ROOT_DIR") || overrides.transform_keys(&:to_s).key?("A3_ROOT_DIR")
          raise KeyError,
                "removed A3 root utility input: environment variable A3_ROOT_DIR; migration_required=true replacement=environment variable A2O_ROOT_DIR"
        end

        {
          "A2O_ROOT_DIR" => ENV.fetch("A2O_ROOT_DIR", Dir.pwd)
        }
      end

      def validate_root_env!(env)
        return unless env.transform_keys(&:to_s).key?("A3_ROOT_DIR")

        raise KeyError,
              "removed A3 root utility input: environment variable A3_ROOT_DIR; migration_required=true replacement=environment variable A2O_ROOT_DIR"
      end

      def workspace_automation_env(workspace)
        workspace_root = workspace.root_path.to_s
        {
          "AUTOMATION_ISSUE_WORKSPACE" => workspace_root
        }
      end

      def expand_command_placeholders(command, workspace:, env:)
        replacements = {
          "workspace_root" => workspace.root_path.to_s,
          "a2o_root_dir" => env.fetch("A2O_ROOT_DIR"),
          "root_dir" => env.fetch("A2O_ROOT_DIR")
        }
        command.to_s.gsub(/\{\{([a-z0-9_]+)\}\}/) do |match|
          value = replacements.fetch(Regexp.last_match(1), nil)
          value.nil? ? match : Shellwords.shellescape(value)
        end
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

      def log_agent_job_event(stage, request:, command_intent:, state: nil, result_status: nil)
        return unless agent_job_trace_enabled?

        warn(
          "runtime_agent_command_event " + JSON.generate(
            {
              "stage" => stage,
              "job_id" => request.job_id,
              "task_ref" => request.task_ref,
              "run_ref" => request.run_ref,
              "phase" => request.phase.to_s,
              "command_intent" => command_intent&.to_s,
              "runtime_profile" => request.runtime_profile,
              "workspace_id" => request.workspace_request&.workspace_id,
              "state" => state&.to_s,
              "result_status" => result_status&.to_s,
              "control_plane_url" => control_plane_url
            }.compact
          )
        )
      rescue StandardError => e
        warn("runtime_agent_command_event stage=#{stage} job_id=#{request.job_id} log_error=#{e.class}:#{e.message}")
      end

      def agent_job_trace_enabled?
        ENV.fetch("A2O_RUNTIME_AGENT_JOB_TRACE", "").strip == "1"
      end
    end
  end
end
