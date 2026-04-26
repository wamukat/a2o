# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "pathname"
require "tmpdir"

module A3
  module Application
    class RunDecompositionInvestigation
      Result = Struct.new(:success, :summary, :result, :request_path, :result_path, :workspace_root, :evidence_path, :failing_command, :observed_state, keyword_init: true)

      def initialize(storage_dir:, project_root: Dir.pwd, process_runner: nil, clock: -> { Time.now.utc })
        @storage_dir = storage_dir
        @project_root = project_root
        @process_runner = process_runner || method(:run_process)
        @clock = clock
      end

      def call(task:, project_surface:, slot_paths: {}, task_snapshot: nil, previous_evidence_path: nil)
        command = project_surface.decomposition_investigate_command
        raise A3::Domain::ConfigurationError, "project.yaml runtime.decomposition.investigate.command must be provided" unless command
        validate_source_task!(task: task, task_snapshot: task_snapshot)

        workspace_root = prepare_workspace_root(task_ref: task.ref)
        isolated_slot_paths = materialize_isolated_slot_paths(slot_paths: slot_paths, workspace_root: workspace_root)
        request_path = File.join(workspace_root, ".a2o", "decomposition-investigate-request.json")
        result_path = File.join(workspace_root, ".a2o", "decomposition-investigate-result.json")
        FileUtils.mkdir_p(File.dirname(request_path))
        FileUtils.rm_f(result_path)
        request = request_payload(
          task: task,
          slot_paths: isolated_slot_paths,
          workspace_root: workspace_root,
          task_snapshot: task_snapshot,
          previous_evidence_path: previous_evidence_path
        )
        write_json(request_path, request)

        command = resolve_command(command)
        stdout, stderr, status = run_command(command: command, workspace_root: workspace_root, request_path: request_path, result_path: result_path)

        result = load_result(result_path)
        success = status.success? && valid_result?(result)
        summary = summary_for(success: success, command: command, status: status, result: result, stderr: stderr)
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
          observed_state: success ? nil : observed_state(status: status, result: result, stderr: stderr)
        )
      end

      private

      CommandStatus = Struct.new(:success?, :exitstatus)

      def run_command(command:, workspace_root:, request_path:, result_path:)
        @process_runner.call(
          command,
          chdir: workspace_root,
          env: {
            "A2O_DECOMPOSITION_REQUEST_PATH" => request_path,
            "A2O_DECOMPOSITION_RESULT_PATH" => result_path,
            "A2O_WORKSPACE_ROOT" => workspace_root
          }
        )
      rescue SystemCallError => e
        ["", e.message, CommandStatus.new(false, nil)]
      end

      def validate_source_task!(task:, task_snapshot:)
        unless task_snapshot.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "decomposition investigation requires source task title and description for #{task.ref}"
        end
        if snapshot_value(task_snapshot, "title").to_s.strip.empty?
          raise A3::Domain::ConfigurationError, "decomposition investigation source task title is missing for #{task.ref}"
        end
        if snapshot_value(task_snapshot, "description").to_s.strip.empty?
          raise A3::Domain::ConfigurationError, "decomposition investigation source task description is missing for #{task.ref}"
        end
      end

      def prepare_workspace_root(task_ref:)
        base_dir = File.join(@storage_dir, "decomposition-workspaces", slugify(task_ref))
        FileUtils.mkdir_p(base_dir)
        Dir.mktmpdir("run-#{@clock.call.strftime('%Y%m%d%H%M%S')}-", base_dir)
      end

      def materialize_isolated_slot_paths(slot_paths:, workspace_root:)
        slots_root = File.join(workspace_root, "slots")
        FileUtils.mkdir_p(slots_root)
        stringify_hash(slot_paths).each_with_object({}) do |(slot, source_path), memo|
          destination = File.join(slots_root, slugify(slot))
          copy_slot(source_path: source_path, destination: destination)
          make_read_only(destination)
          memo[slot] = destination
        end
      end

      def copy_slot(source_path:, destination:)
        raise A3::Domain::ConfigurationError, "decomposition slot path does not exist: #{source_path}" unless File.exist?(source_path)

        if File.directory?(source_path)
          FileUtils.mkdir_p(destination)
          entries = Dir.children(source_path)
          FileUtils.cp_r(entries.map { |entry| File.join(source_path, entry) }, destination) unless entries.empty?
        else
          FileUtils.mkdir_p(File.dirname(destination))
          FileUtils.cp(source_path, destination)
        end
      end

      def make_read_only(path)
        FileUtils.chmod_R("a-w", path)
      end

      def resolve_command(command)
        first, *rest = command
        resolved_first =
          if relative_path_command?(first)
            File.expand_path(first, @project_root)
          else
            first
          end
        [resolved_first, *rest]
      end

      def relative_path_command?(value)
        value.include?(File::SEPARATOR) && Pathname.new(value).relative?
      end

      def request_payload(task:, slot_paths:, workspace_root:, task_snapshot:, previous_evidence_path:)
        previous_evidence = load_previous_evidence(previous_evidence_path)
        {
          "task_ref" => task.ref,
          "task_kind" => task.kind.to_s,
          "title" => snapshot_value(task_snapshot, "title"),
          "description" => snapshot_value(task_snapshot, "description"),
          "labels" => task.labels,
          "priority" => task.priority,
          "parent_ref" => task.parent_ref,
          "child_refs" => task.child_refs,
          "blocking_task_refs" => task.blocking_task_refs,
          "source_task" => source_task_payload(task_snapshot),
          "previous_evidence_path" => previous_evidence_path,
          "previous_evidence_summary" => previous_evidence && previous_evidence["summary"],
          "slot_paths" => stringify_hash(slot_paths),
          "workspace_root" => workspace_root
        }
      end

      def load_previous_evidence(path)
        return nil unless path && File.exist?(path)

        payload = JSON.parse(File.read(path))
        payload.is_a?(Hash) ? payload : nil
      rescue JSON::ParserError
        nil
      end

      def source_task_payload(task_snapshot)
        return nil unless task_snapshot.is_a?(Hash)

        {
          "id" => task_snapshot["task_id"] || task_snapshot["id"],
          "ref" => task_snapshot["ref"],
          "title" => snapshot_value(task_snapshot, "title"),
          "description" => snapshot_value(task_snapshot, "description"),
          "status" => task_snapshot["status"],
          "labels" => Array(task_snapshot["labels"]).map(&:to_s),
          "parent_ref" => task_snapshot["parent_ref"]
        }.compact
      end

      def snapshot_value(task_snapshot, key)
        return nil unless task_snapshot.is_a?(Hash)

        value = task_snapshot[key] || task_snapshot[key.to_sym]
        value && value.to_s
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

      def summary_for(success:, command:, status:, result:, stderr:)
        return result.fetch("summary") if success
        return "#{command.join(' ')} failed to launch: #{stderr}" if status.exitstatus.nil?
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

      def observed_state(status:, result:, stderr:)
        return "launch_error: #{stderr}" if status.exitstatus.nil?
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
