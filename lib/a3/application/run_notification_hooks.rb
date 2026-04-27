# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "shellwords"
require "time"
require "a3/infra/local_command_runner"
require "a3/infra/workspace_trace_logger"

module A3
  module Application
    class RunNotificationHooks
      Result = Struct.new(:run, :hook_results, keyword_init: true) do
        def failed?
          hook_results.any? { |result| result.fetch("success") == false }
        end
      end

      def initialize(command_runner: A3::Infra::LocalCommandRunner.new, clock: -> { Time.now.utc })
        @command_runner = command_runner
        @clock = clock
      end

      def call(events:, task:, run:, runtime:, workspace:)
        hook_results = []
        Array(events).each do |event|
          runtime.notification_config.hooks_for(event).each_with_index do |hook, index|
            hook_results << execute_hook(
              event: event.to_s,
              hook: hook,
              hook_index: index,
              task: task,
              run: run,
              workspace: workspace
            )
          end
        end

        return Result.new(run: run, hook_results: []) if hook_results.empty?

        Result.new(
          run: run_with_hook_results(run: run, hook_results: hook_results),
          hook_results: hook_results
        )
      end

      private

      def execute_hook(event:, hook:, hook_index:, task:, run:, workspace:)
        payload = payload_for(event: event, task: task, run: run)
        payload_path = payload_path_for(payload: payload, event: event, hook_index: hook_index, run: run, workspace: workspace)
        started_at = @clock.call
        A3::Infra::WorkspaceTraceLogger.log(
          workspace_root: workspace.root_path,
          event: "notification_hook.start",
          payload: {
            "notification_event" => event,
            "command" => hook.command,
            "payload_path" => payload_path
          }
        )
        result = run_command(command: hook.command, workspace: workspace, payload: payload, payload_path: payload_path, task: task, run: run)
        finished_at = @clock.call
        record = result.merge(
          "event" => event,
          "command" => hook.command,
          "payload_path" => payload_path,
          "started_at" => started_at.iso8601,
          "finished_at" => finished_at.iso8601,
          "duration_ms" => ((finished_at - started_at) * 1000).round
        )
        A3::Infra::WorkspaceTraceLogger.log(
          workspace_root: workspace.root_path,
          event: "notification_hook.finish",
          payload: record.slice("event", "command", "exit_status", "success")
        )
        record
      end

      def payload_path_for(payload:, event:, hook_index:, run:, workspace:)
        return "$A2O_WORKER_REQUEST_PATH" if agent_owned_workspace?

        dir = File.join(workspace.root_path.to_s, ".a2o", "notifications")
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "#{safe_id(run.ref)}-#{event.tr('.', '-')}-#{hook_index}-#{SecureRandom.hex(4)}.json")
        File.write(path, JSON.pretty_generate(payload))
        path
      end

      def payload_for(event:, task:, run:)
        latest = run.phase_records.last
        execution_record = latest&.execution_record
        blocked_diagnosis = latest&.blocked_diagnosis
        diagnostics = execution_record&.diagnostics || {}
        diagnostics = diagnostics.merge(
          "blocked_diagnosis" => {
            "error_category" => blocked_diagnosis.error_category,
            "diagnostic_summary" => blocked_diagnosis.diagnostic_summary,
            "failing_command" => blocked_diagnosis.failing_command,
            "observed_state" => blocked_diagnosis.observed_state,
            "infra_diagnostics" => blocked_diagnosis.infra_diagnostics
          }
        ) if blocked_diagnosis

        {
          "schema" => "a2o.notification/v1",
          "event" => event,
          "task_ref" => task.ref,
          "task_kind" => task.kind.to_s,
          "status" => task.status.to_s,
          "run_ref" => run.ref,
          "phase" => run.phase.to_s,
          "terminal_outcome" => run.terminal_outcome&.to_s,
          "parent_ref" => task.parent_ref,
          "summary" => execution_record&.summary,
          "diagnostics" => diagnostics,
          "timestamp" => @clock.call.iso8601
        }
      end

      def run_command(command:, workspace:, payload:, payload_path:, task:, run:)
        execution = @command_runner.run(
          [shell_command_for(command)],
          workspace: workspace,
          env: notification_env(payload_path),
          task: task,
          run: run,
          command_intent: :notification,
          worker_protocol_request: notification_worker_protocol_request(payload)
        )
        {
          "success" => execution.success?,
          "exit_status" => exit_status_from(execution),
          "stdout" => execution.diagnostics.fetch("stdout", ""),
          "stderr" => execution.diagnostics.fetch("stderr", ""),
          "summary" => execution.summary,
          "failing_command" => execution.failing_command,
          "observed_state" => execution.observed_state
        }
      rescue SystemCallError, ArgumentError, KeyError => e
        {
          "success" => false,
          "exit_status" => nil,
          "stdout" => "",
          "stderr" => "#{e.class}: #{e.message}"
        }
      end

      def exit_status_from(execution)
        return 0 if execution.success?

        match = execution.observed_state.to_s.match(/\Aexit\s+(\d+)\z/)
        return Integer(match[1]) if match

        agent_job_result = execution.diagnostics["agent_job_result"]
        return agent_job_result["exit_code"] if agent_job_result.is_a?(Hash) && agent_job_result.key?("exit_code")

        nil
      end

      def shell_command_for(command)
        command_text = Shellwords.join(command)
        return command_text unless agent_owned_workspace?

        "A2O_NOTIFICATION_EVENT_PATH=\"$A2O_WORKER_REQUEST_PATH\" #{command_text}"
      end

      def notification_env(payload_path)
        return {} if agent_owned_workspace?

        { "A2O_NOTIFICATION_EVENT_PATH" => payload_path }
      end

      def notification_worker_protocol_request(payload)
        return nil unless agent_owned_workspace?

        payload.merge("command_intent" => "notification")
      end

      def agent_owned_workspace?
        @command_runner.respond_to?(:agent_owned_workspace?) && @command_runner.agent_owned_workspace?
      end

      def run_with_hook_results(run:, hook_results:)
        latest = run.phase_records.last
        return run unless latest&.execution_record

        diagnostics = latest.execution_record.diagnostics.merge(
          "notification_hooks" => Array(latest.execution_record.diagnostics["notification_hooks"]) + hook_results
        )
        run.replace_latest_phase_record(latest.with_execution_record(latest.execution_record.with_diagnostics(diagnostics)))
      end

      def safe_id(value)
        value.to_s.gsub(/[^A-Za-z0-9._:-]/, "-")
      end
    end
  end
end
