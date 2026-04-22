# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "a3/infra/workspace_trace_logger"

module A3
  module Infra
    class AgentWorkerGateway
      def initialize(control_plane_client:, worker_command:, worker_command_args: [], runtime_profile:, shared_workspace_mode:, timeout_seconds: 1800, poll_interval_seconds: 1.0, job_id_generator: -> { SecureRandom.uuid }, sleeper: ->(seconds) { sleep(seconds) }, monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, worker_protocol: A3::Infra::WorkerProtocol.new, workspace_request_builder: nil, env: {}, agent_environment: nil)
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
        @env = env.transform_keys(&:to_s).transform_values(&:to_s).freeze
        @agent_environment = agent_environment
      end

      def run(skill:, workspace:, task:, run:, phase_runtime:, task_packet:)
        return invalid_configuration_result("worker_command must be provided") if @worker_command.empty?
        return run_same_path(skill: skill, workspace: workspace, task: task, run: run, phase_runtime: phase_runtime, task_packet: task_packet) if @shared_workspace_mode == "same-path"
        return run_agent_materialized(skill: skill, workspace: workspace, task: task, run: run, phase_runtime: phase_runtime, task_packet: task_packet) if @shared_workspace_mode == "agent-materialized"

        unsupported_workspace_result
      end

      def agent_owned_publication?
        @shared_workspace_mode == "agent-materialized"
      end

      def agent_owned_workspace?
        @shared_workspace_mode == "agent-materialized"
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
        return with_agent_job_result(execution, completed.result) if execution
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

        descriptor_validation = materialized_changed_files_evidence(
          workspace_request: request.workspace_request,
          result: completed.result,
          require_changed_files: false
        )
        return descriptor_validation if descriptor_validation.is_a?(A3::Application::ExecutionResult)

        worker_response = completed.result.worker_protocol_result
        canonical_changed_files = nil
        if run.phase.to_sym == :implementation && worker_response&.fetch("success", nil) == true
          evidence = materialized_changed_files_evidence(
            workspace_request: request.workspace_request,
            result: completed.result,
            require_changed_files: true
          )
          return evidence if evidence.is_a?(A3::Application::ExecutionResult)

          publish_result = materialized_publish_evidence(workspace_request: request.workspace_request, result: completed.result)
          return publish_result if publish_result.is_a?(A3::Application::ExecutionResult)

          return missing_agent_publish_policy_result(completed.result) unless request.workspace_request.publish_policy

          canonical_changed_files = evidence
        end
        execution = @worker_protocol.build_execution_result(
          worker_response,
          workspace: workspace,
          expected_task_ref: task.ref,
          expected_run_ref: run.ref,
          expected_phase: run.phase,
          canonical_changed_files: canonical_changed_files
        )
        return with_agent_job_result(execution, completed.result) if execution

        @worker_protocol.missing_result
      end

      def build_job_request(workspace:, task:, run:, workspace_request: nil, worker_protocol_request: nil)
        A3::Domain::AgentJobRequest.new(
          job_id: job_id_for(run),
          task_ref: task.ref,
          run_ref: run.ref,
          phase: run.phase,
          runtime_profile: @runtime_profile,
          source_descriptor: run.source_descriptor,
          workspace_request: workspace_request,
          worker_protocol_request: worker_protocol_request,
          agent_environment: @agent_environment,
          working_dir: workspace.root_path.to_s,
          command: @worker_command,
          args: @worker_command_args,
          env: @worker_protocol.env_for(workspace).merge(@env),
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

      def materialized_changed_files_evidence(workspace_request:, result:, require_changed_files: true)
        errors = []
        slots = result.workspace_descriptor.slot_descriptors
        canonical_changed_files = {}
        workspace_request.slots.each do |slot_name, request_slot|
          next unless request_slot.fetch("required")

          descriptor = slots[slot_name]
          if descriptor.nil?
            errors << "workspace descriptor missing required slot #{slot_name}"
            next
          end
          source = request_slot.fetch("source")
          {
            "source_kind" => source.fetch("kind"),
            "source_alias" => source.fetch("alias"),
            "checkout" => request_slot.fetch("checkout"),
            "requested_ref" => request_slot.fetch("ref"),
            "branch_ref" => request_slot.fetch("ref"),
            "access" => request_slot.fetch("access"),
            "sync_class" => request_slot.fetch("sync_class"),
            "ownership" => request_slot.fetch("ownership")
          }.each do |key, expected|
            errors << "#{slot_name}.#{key} must match workspace_request" unless descriptor[key] == expected
          end
          errors << "#{slot_name}.runtime_path must be present" unless descriptor["runtime_path"].is_a?(String) && !descriptor["runtime_path"].empty?
          errors << "#{slot_name}.resolved_head must be present" unless descriptor["resolved_head"].is_a?(String) && !descriptor["resolved_head"].empty?
          errors << "#{slot_name}.dirty_before must be false" unless descriptor["dirty_before"] == false
          errors << "#{slot_name}.dirty_after must be true or false" unless [true, false].include?(descriptor["dirty_after"])
          if require_changed_files
            changed_files = descriptor["changed_files"]
            unless changed_files.is_a?(Array) && changed_files.all? { |entry| entry.is_a?(String) }
              errors << "#{slot_name}.changed_files must be an array of strings"
              next
            end
            canonical_changed_files[slot_name] = changed_files.sort.uniq
          end
        end
        return canonical_changed_files if errors.empty?

        A3::Application::ExecutionResult.new(
          success: false,
          summary: "agent materialized implementation changed_files evidence is invalid",
          failing_command: "agent_materialized_changed_files",
          observed_state: "agent_materialized_changed_files_invalid",
          diagnostics: {
            "validation_errors" => errors,
            "agent_job_result" => result.result_form,
            "control_plane_url" => control_plane_url
          },
          response_bundle: {
            "agent_job_result" => result.result_form
          }
        )
      end

      def materialized_publish_evidence(workspace_request:, result:)
        return nil unless workspace_request.publish_policy

        errors = []
        result.workspace_descriptor.slot_descriptors.each do |slot_name, descriptor|
          request_slot = workspace_request.slots[slot_name] || workspace_request.slots[slot_name.to_sym]
          next unless request_slot&.fetch("required")

          if request_slot.fetch("access") == "read_write" && request_slot.fetch("ownership") == "edit_target"
            status = descriptor["publish_status"]
            errors << "#{slot_name}.publish_status must be committed or no_changes" unless %w[committed no_changes].include?(status)
            errors << "#{slot_name}.published must be true or false" unless [true, false].include?(descriptor["published"])
            if status == "committed"
              errors << "#{slot_name}.published must be true when committed" unless descriptor["published"] == true
              errors << "#{slot_name}.publish_before_head must be present" unless descriptor["publish_before_head"].is_a?(String) && !descriptor["publish_before_head"].empty?
              errors << "#{slot_name}.publish_after_head must be present" unless descriptor["publish_after_head"].is_a?(String) && !descriptor["publish_after_head"].empty?
              errors << "#{slot_name}.publish_after_head must differ from publish_before_head" if descriptor["publish_after_head"] == descriptor["publish_before_head"]
              errors << "#{slot_name}.publish_after_head must match resolved_head" unless descriptor["publish_after_head"] == descriptor["resolved_head"]
            end
          elsif descriptor["publish_status"] != "skipped"
            errors << "#{slot_name}.publish_status must be skipped for non-edit slots"
          end
        end
        return nil if errors.empty?

        A3::Application::ExecutionResult.new(
          success: false,
          summary: "agent materialized publish evidence is invalid",
          failing_command: "agent_materialized_publish_evidence",
          observed_state: "agent_materialized_publish_evidence_invalid",
          diagnostics: {
            "validation_errors" => errors,
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

      def missing_agent_publish_policy_result(result)
        A3::Application::ExecutionResult.new(
          success: false,
          summary: "agent materialized implementation requires publish_policy",
          failing_command: "agent_materialized_publish_policy",
          observed_state: "agent_materialized_publish_policy_missing",
          diagnostics: {
            "agent_job_result" => result.result_form,
            "control_plane_url" => control_plane_url
          },
          response_bundle: {
            "agent_job_result" => result.result_form
          }
        )
      end

      def with_agent_job_result(execution, result)
        diagnostics = execution.diagnostics.merge(
          "agent_artifacts" => agent_artifacts_from_result(result)
        )
        A3::Application::ExecutionResult.new(
          success: execution.success,
          summary: execution.summary,
          failing_command: execution.failing_command,
          observed_state: execution.observed_state,
          diagnostics: diagnostics,
          response_bundle: execution.response_bundle
        )
      end

      def agent_artifacts_from_result(result)
        (result.log_uploads + result.artifact_uploads).map(&:persisted_form)
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
