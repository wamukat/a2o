# frozen_string_literal: true

require "json"
require "fileutils"
require "open3"
require "shellwords"
require "a3/infra/workspace_trace_logger"

module A3
  module Infra
    class LocalWorkerGateway
      def initialize(command_runner: A3::Infra::LocalCommandRunner.new, worker_command: nil, worker_command_args: [])
        @command_runner = command_runner
        @worker_command = worker_command
        @worker_command_args = Array(worker_command_args).freeze
      end

      def run(skill:, workspace:, task:, run:, phase_runtime:, task_packet:)
        result_path = worker_result_path(workspace)
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
        write_worker_request(
          skill: skill,
          workspace: workspace,
          task: task,
          run: run,
          phase_runtime: phase_runtime,
          task_packet: task_packet
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
        @command_runner.run(
          [command],
          workspace: workspace,
          env: {
            "A3_WORKER_REQUEST_PATH" => workspace.root_path.join(".a3", "worker-request.json").to_s,
            "A3_WORKER_RESULT_PATH" => result_path.to_s,
            "A3_WORKSPACE_ROOT" => workspace.root_path.to_s
          }
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
          worker_response = load_worker_result(result_path)
          if worker_response.is_a?(A3::Application::ExecutionResult)
            worker_response
          else
            build_execution_result(
              worker_response,
              workspace: workspace,
              expected_task_ref: task.ref,
              expected_run_ref: run.ref,
              expected_phase: run.phase
            ) || execution_result
          end
        end
      end

      private

      def worker_result_path(workspace)
        workspace.root_path.join(".a3", "worker-result.json")
      end

      def worker_command_for(skill)
        return skill unless @worker_command

        Shellwords.join([@worker_command, *@worker_command_args])
      end

      def write_worker_request(skill:, workspace:, task:, run:, phase_runtime:, task_packet:)
        review_target = run.evidence.review_target
        metadata_dir = workspace.root_path.join(".a3")
        FileUtils.mkdir_p(metadata_dir)
        metadata_dir.join("worker-request.json").write(
          JSON.pretty_generate(
            "task_ref" => task.ref,
            "run_ref" => run.ref,
            "phase" => run.phase.to_s,
            "skill" => skill,
            "workspace_kind" => workspace.workspace_kind.to_s,
            "source_descriptor" => {
              "workspace_kind" => run.source_descriptor.workspace_kind.to_s,
              "source_type" => run.source_descriptor.source_type.to_s,
              "ref" => run.source_descriptor.ref,
              "task_ref" => run.source_descriptor.task_ref
            },
            "scope_snapshot" => {
              "edit_scope" => run.scope_snapshot.edit_scope.map(&:to_s),
              "verification_scope" => run.scope_snapshot.verification_scope.map(&:to_s),
              "ownership_scope" => run.scope_snapshot.ownership_scope.to_s
            },
            "artifact_owner" => {
              "owner_ref" => run.artifact_owner.owner_ref,
              "owner_scope" => run.artifact_owner.owner_scope.to_s,
              "snapshot_version" => run.artifact_owner.snapshot_version
            },
            "task_packet" => task_packet.request_form,
            "review_target" => review_target && {
              "base_commit" => review_target.base_commit,
              "head_commit" => review_target.head_commit,
              "task_ref" => review_target.task_ref,
              "phase_ref" => review_target.phase_ref.to_s
            },
            "phase_runtime" => phase_runtime.worker_request_form,
            "slot_paths" => workspace.slot_paths.transform_values(&:to_s)
          )
        )
      end

      def load_worker_result(result_path)
        return nil unless result_path.exist?

        raw_content = result_path.read
        parsed = JSON.parse(raw_content)
        return parsed unless parsed.nil?

        A3::Application::ExecutionResult.new(
          success: false,
          summary: "worker result schema invalid",
          failing_command: "worker_result_schema",
          observed_state: "invalid_worker_result",
          diagnostics: { "validation_errors" => ["worker result payload must be an object"] },
          response_bundle: { "raw" => raw_content }
        )
      rescue JSON::ParserError
        A3::Application::ExecutionResult.new(
          success: false,
          summary: "worker result json invalid",
          failing_command: "worker_result_json",
          observed_state: "invalid_worker_result",
          diagnostics: { "validation_errors" => ["worker result file is not valid JSON"] },
          response_bundle: { "raw" => raw_content }
        )
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end

      def build_execution_result(worker_response, workspace:, expected_task_ref:, expected_run_ref:, expected_phase:)
        return nil if worker_response.nil?

        unless worker_response.is_a?(Hash)
          return A3::Application::ExecutionResult.new(
            success: false,
            summary: "worker result schema invalid",
            failing_command: "worker_result_schema",
            observed_state: "invalid_worker_result",
            diagnostics: { "validation_errors" => ["worker result payload must be an object"] },
            response_bundle: worker_response
          )
        end
        validation_errors = validate_worker_response(
          worker_response,
          expected_task_ref: expected_task_ref,
          expected_run_ref: expected_run_ref,
          expected_phase: expected_phase
        )
        unless validation_errors.empty?
          A3::Infra::WorkspaceTraceLogger.log(
            workspace_root: workspace.root_path,
            event: "worker_gateway.result.invalid",
            payload: {
              "task_ref" => expected_task_ref,
              "run_ref" => expected_run_ref,
              "phase" => expected_phase.to_s,
              "validation_errors" => validation_errors
            }
          )
          return A3::Application::ExecutionResult.new(
            success: false,
            summary: "worker result schema invalid",
            failing_command: "worker_result_schema",
            observed_state: "invalid_worker_result",
            diagnostics: { "validation_errors" => validation_errors },
            response_bundle: worker_response
          )
        end

        diagnostics = worker_response["diagnostics"].is_a?(Hash) ? worker_response["diagnostics"].dup : {}
        response_bundle = canonicalize_response_bundle(
          worker_response,
          workspace: workspace,
          expected_phase: expected_phase,
          diagnostics: diagnostics
        )

        A3::Application::ExecutionResult.new(
          success: worker_response.fetch("success"),
          summary: worker_response.fetch("summary"),
          failing_command: worker_response["failing_command"],
          observed_state: worker_response["observed_state"],
          diagnostics: diagnostics,
          response_bundle: response_bundle
        )
      end

      def canonicalize_response_bundle(worker_response, workspace:, expected_phase:, diagnostics:)
        return worker_response unless expected_phase.to_s == "implementation" && worker_response["success"] == true

        canonical_changed_files = changed_files_from_workspace(workspace)
        worker_changed_files = worker_response["changed_files"]
        if worker_changed_files != canonical_changed_files
          diagnostics["worker_changed_files"] = worker_changed_files
          diagnostics["canonical_changed_files"] = canonical_changed_files
        end

        worker_response.merge("changed_files" => canonical_changed_files)
      end

      def validate_worker_response(worker_response, expected_task_ref:, expected_run_ref:, expected_phase:)
        implementation_phase = expected_phase.to_s == "implementation"
        parent_review = expected_phase.to_s == "review"
        errors = []
        errors << "success must be true or false" unless [true, false].include?(worker_response["success"])
        errors << "summary must be a string" unless worker_response["summary"].is_a?(String)
        if worker_response.key?("task_ref") && worker_response["task_ref"] != expected_task_ref
          errors << "task_ref must match the worker request"
        end
        if worker_response.key?("run_ref") && worker_response["run_ref"] != expected_run_ref
          errors << "run_ref must match the worker request"
        end
        if worker_response.key?("phase") && worker_response["phase"] != expected_phase.to_s
          errors << "phase must match the worker request"
        end
        if worker_response.key?("review_disposition")
          disposition = worker_response["review_disposition"]
          unless disposition.is_a?(Hash)
            errors << "review_disposition must be an object when present"
            return errors
          end

          %w[kind repo_scope summary description finding_key].each do |key|
            errors << "review_disposition.#{key} must be present" unless disposition[key].is_a?(String)
          end
          if parent_review
            valid_kinds = %w[completed follow_up_child blocked]
            valid_repo_scopes = %w[repo_alpha repo_beta both unresolved]
            unless valid_kinds.include?(disposition["kind"])
              errors << "review_disposition.kind must be one of #{valid_kinds.join(', ')}"
            end
            unless valid_repo_scopes.include?(disposition["repo_scope"])
              errors << "review_disposition.repo_scope must be one of #{valid_repo_scopes.join(', ')}"
            end
          end
        end
        if worker_response.fetch("success", nil) == false &&
           worker_response["rework_required"] != true &&
           !worker_response["failing_command"].is_a?(String)
          errors << "failing_command must be a string when success is false unless rework_required is true"
        elsif worker_response.key?("failing_command") && !worker_response["failing_command"].nil? && !worker_response["failing_command"].is_a?(String)
          errors << "failing_command must be a string when present"
        end
        if worker_response.key?("observed_state") && !worker_response["observed_state"].nil? && !worker_response["observed_state"].is_a?(String)
          errors << "observed_state must be a string when present"
        elsif worker_response.fetch("success", nil) == false && !worker_response["observed_state"].is_a?(String)
          errors << "observed_state must be a string when success is false"
        end
        diagnostics = worker_response["diagnostics"]
        if worker_response.key?("diagnostics") && !diagnostics.is_a?(Hash)
          errors << "diagnostics must be an object"
        end
        unless [true, false].include?(worker_response["rework_required"])
          errors << "rework_required must be true or false"
        end
        if worker_response.key?("changed_files")
          changed_files = worker_response["changed_files"]
          unless changed_files.nil? || changed_files.is_a?(Hash)
            errors << "changed_files must be an object when present"
            return errors
          end
          return errors if changed_files.nil?

          changed_files.each do |slot_name, files|
            errors << "changed_files slot names must be strings" unless slot_name.is_a?(String)
            unless files.is_a?(Array) && files.all? { |entry| entry.is_a?(String) }
              errors << "changed_files for #{slot_name} must be an array of strings"
            end
          end
        elsif implementation_phase && worker_response.fetch("success", nil) == true
          errors << "changed_files must be present for implementation success"
        end
        errors
      end

      def changed_files_from_workspace(workspace)
        workspace.slot_paths.each_with_object({}) do |(slot_name, slot_path), entries|
          next unless git_repo?(slot_path)

          changed_paths = git_changed_paths(slot_path)
          next if changed_paths.empty?

          entries[slot_name.to_s] = changed_paths
        end
      end

      def git_repo?(slot_path)
        _stdout, _stderr, status = Open3.capture3("git", "-C", slot_path.to_s, "rev-parse", "--is-inside-work-tree")
        status.success?
      end

      def git_changed_paths(slot_path)
        stdout, stderr, status = Open3.capture3(
          "git", "-C", slot_path.to_s, "status", "--porcelain", "--untracked-files=all", "--", ".", ":(exclude).a3"
        )
        raise A3::Domain::ConfigurationError, "git status failed: #{stderr}" unless status.success?

        stdout.each_line.map do |line|
          path = line[3..]&.strip
          next if path.nil? || path.empty?

          path.include?(" -> ") ? path.split(" -> ", 2).last : path
        end.compact.uniq.sort
      end
    end
  end
end
