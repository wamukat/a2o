# frozen_string_literal: true

require "open3"
require "a3/infra/workspace_trace_logger"

module A3
  module Infra
    class LocalCommandRunner
      def run(commands, workspace:, env: {}, **)
        command_env = default_env.merge(env)
        results = Array(commands).map do |command|
          A3::Infra::WorkspaceTraceLogger.log(
            workspace_root: workspace.root_path,
            event: "command_runner.command.start",
            payload: { "command" => command }
          )
          stdout, stderr, status = Open3.capture3(command_env, command, chdir: workspace.root_path.to_s)
          A3::Infra::WorkspaceTraceLogger.log(
            workspace_root: workspace.root_path,
            event: "command_runner.command.finish",
            payload: {
              "command" => command,
              "exit_status" => status.exitstatus,
              "success" => status.success?
            }
          )
          return A3::Application::ExecutionResult.new(
            success: false,
            summary: "#{command} failed",
            failing_command: command,
            observed_state: "exit #{status.exitstatus}",
            diagnostics: { "stdout" => stdout, "stderr" => stderr }
          ) unless status.success?

          "#{command} ok"
        end

        A3::Application::ExecutionResult.new(
          success: true,
          summary: results.join("; ")
        )
      end

      private

      def default_env
        {
          "A3_ROOT_DIR" => ENV.fetch("A3_ROOT_DIR", Dir.pwd),
          "A2O_ROOT_DIR" => ENV.fetch("A2O_ROOT_DIR", ENV.fetch("A3_ROOT_DIR", Dir.pwd))
        }
      end
    end
  end
end
