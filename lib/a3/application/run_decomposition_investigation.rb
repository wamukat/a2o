# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"

module A3
  module Application
    class RunDecompositionInvestigation
      Result = Struct.new(:success, :summary, :result, :request_path, :result_path, :workspace_root, :evidence_path, :failing_command, :observed_state, keyword_init: true)

      def initialize(storage_dir:, process_runner: nil, clock: -> { Time.now.utc })
        @storage_dir = storage_dir
        @process_runner = process_runner || method(:run_process)
        @clock = clock
      end

      def call(task:, project_surface:, slot_paths: {})
        command = project_surface.decomposition_investigate_command
        raise A3::Domain::ConfigurationError, "project.yaml runtime.decomposition.investigate.command must be provided" unless command

        workspace_root = prepare_workspace_root(task_ref: task.ref)
        request_path = File.join(workspace_root, ".a2o", "decomposition-investigate-request.json")
        result_path = File.join(workspace_root, ".a2o", "decomposition-investigate-result.json")
        FileUtils.mkdir_p(File.dirname(request_path))
        request = request_payload(task: task, slot_paths: slot_paths, workspace_root: workspace_root)
        write_json(request_path, request)

        stdout, stderr, status = @process_runner.call(
          command,
          chdir: workspace_root,
          env: {
            "A2O_DECOMPOSITION_REQUEST_PATH" => request_path,
            "A2O_DECOMPOSITION_RESULT_PATH" => result_path,
            "A2O_WORKSPACE_ROOT" => workspace_root
          }
        )

        result = load_result(result_path)
        success = status.success? && valid_result?(result)
        summary = summary_for(success: success, command: command, status: status, result: result)
        evidence_path = persist_evidence(
          task: task,
          command: command,
          request: request,
          result: result,
          success: success,
          summary: summary,
          stdout: stdout,
          stderr: stderr,
          status: status,
          workspace_root: workspace_root,
          request_path: request_path,
          result_path: result_path
        )

        Result.new(
          success: success,
          summary: summary,
          result: result,
          request_path: request_path,
          result_path: result_path,
          workspace_root: workspace_root,
          evidence_path: evidence_path,
          failing_command: success ? nil : command.join(" "),
          observed_state: success ? nil : observed_state(status: status, result: result)
        )
      end

      private

      def prepare_workspace_root(task_ref:)
        root = File.join(
          @storage_dir,
          "decomposition-workspaces",
          slugify(task_ref),
          @clock.call.strftime("%Y%m%d%H%M%S")
        )
        FileUtils.mkdir_p(root)
        root
      end

      def request_payload(task:, slot_paths:, workspace_root:)
        {
          "task_ref" => task.ref,
          "task_kind" => task.kind.to_s,
          "title" => nil,
          "labels" => task.labels,
          "priority" => task.priority,
          "parent_ref" => task.parent_ref,
          "child_refs" => task.child_refs,
          "blocking_task_refs" => task.blocking_task_refs,
          "slot_paths" => stringify_hash(slot_paths),
          "workspace_root" => workspace_root
        }
      end

      def load_result(result_path)
        return nil unless File.exist?(result_path)

        payload = JSON.parse(File.read(result_path))
        payload.is_a?(Hash) ? payload : nil
      rescue JSON::ParserError
        nil
      end

      def valid_result?(result)
        result.is_a?(Hash) && result["summary"].is_a?(String) && !result["summary"].strip.empty?
      end

      def summary_for(success:, command:, status:, result:)
        return result.fetch("summary") if success
        return "#{command.join(' ')} failed with exit #{status.exitstatus}" unless status.success?
        return "investigation result JSON is missing or invalid" unless result

        "investigation result summary must be a non-empty string"
      end

      def persist_evidence(task:, command:, request:, result:, success:, summary:, stdout:, stderr:, status:, workspace_root:, request_path:, result_path:)
        evidence_dir = File.join(@storage_dir, "decomposition-evidence", slugify(task.ref))
        FileUtils.mkdir_p(evidence_dir)
        evidence_path = File.join(evidence_dir, "investigation.json")
        write_json(
          evidence_path,
          {
            "task_ref" => task.ref,
            "phase" => "investigation",
            "success" => success,
            "summary" => summary,
            "command" => command,
            "exit_status" => status.exitstatus,
            "request_path" => request_path,
            "result_path" => result_path,
            "workspace_root" => workspace_root,
            "request" => request,
            "result" => result,
            "stdout" => stdout,
            "stderr" => stderr
          }
        )
        evidence_path
      end

      def observed_state(status:, result:)
        return "exit #{status.exitstatus}" unless status.success?
        return "missing_or_invalid_result_json" unless result

        "invalid_result_summary"
      end

      def stringify_hash(value)
        value.each_with_object({}) do |(key, item), memo|
          memo[key.to_s] = item.to_s
        end
      end

      def write_json(path, payload)
        File.write(path, "#{JSON.pretty_generate(payload)}\n")
      end

      def slugify(value)
        value.to_s.gsub(/[^A-Za-z0-9._-]+/, "-")
      end

      def run_process(command, chdir:, env:)
        stdout, stderr, status = Open3.capture3(env, *command, chdir: chdir)
        [stdout, stderr, status]
      end
    end
  end
end
