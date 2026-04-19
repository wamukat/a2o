# frozen_string_literal: true

require "open3"
require "shellwords"
require "a3/infra/workspace_trace_logger"

module A3
  module Infra
    class LocalCommandRunner
      def run(commands, workspace:, env: {}, **)
        command_env = default_env.merge(env)
        results = Array(commands).map do |command|
          expanded_command = expand_command_placeholders(command, workspace: workspace, env: command_env)
          A3::Infra::WorkspaceTraceLogger.log(
            workspace_root: workspace.root_path,
            event: "command_runner.command.start",
            payload: { "command" => expanded_command }
          )
          stdout, stderr, status = Open3.capture3(command_env, expanded_command, chdir: workspace.root_path.to_s)
          A3::Infra::WorkspaceTraceLogger.log(
            workspace_root: workspace.root_path,
            event: "command_runner.command.finish",
            payload: {
              "command" => expanded_command,
              "exit_status" => status.exitstatus,
              "success" => status.success?
            }
          )
          return A3::Application::ExecutionResult.new(
            success: false,
            summary: "#{expanded_command} failed",
            failing_command: expanded_command,
            observed_state: "exit #{status.exitstatus}",
            diagnostics: { "stdout" => stdout, "stderr" => stderr }
          ) unless status.success?

          "#{expanded_command} ok"
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
    end
  end
end
