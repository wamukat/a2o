# frozen_string_literal: true

require "json"
require "securerandom"

module A3
  module Infra
    class AgentMergeRunner
      def initialize(control_plane_client:, runtime_profile:, source_aliases:, timeout_seconds: 1800, poll_interval_seconds: 1.0, job_id_generator: -> { SecureRandom.uuid }, sleeper: ->(seconds) { sleep(seconds) }, monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, agent_environment: nil, merge_recovery_command: nil, merge_recovery_args: [], merge_recovery_env: {})
        @control_plane_client = control_plane_client
        @runtime_profile = runtime_profile.to_s
        @source_aliases = source_aliases.transform_keys(&:to_sym).transform_values(&:to_s).freeze
        @timeout_seconds = Integer(timeout_seconds)
        @poll_interval_seconds = Float(poll_interval_seconds)
        @job_id_generator = job_id_generator
        @sleeper = sleeper
        @monotonic_clock = monotonic_clock
        @agent_environment = agent_environment
        @merge_recovery_command = merge_recovery_command&.to_s
        @merge_recovery_args = Array(merge_recovery_args).map(&:to_s).freeze
        @merge_recovery_env = merge_recovery_env.transform_keys(&:to_s).transform_values(&:to_s).freeze
      end

      def run(merge_plan, workspace:)
        workspace
        request = build_job_request(merge_plan)
        record = enqueue(request)
        return record if record.is_a?(A3::Application::ExecutionResult)

        completed = wait_for_completion(request.job_id)
        return completed if completed.is_a?(A3::Application::ExecutionResult)

        result = completed.result
        unless result.succeeded?
          recovery_candidate = merge_recovery_candidate(merge_plan, result)
          recovery_result = run_merge_recovery(merge_plan, recovery_candidate, result) if recovery_candidate && merge_recovery_enabled?
          return recovery_result if recovery_result

          return failed_merge_result(merge_plan, result, recovery_candidate: recovery_candidate)
        end

        evidence = validate_merge_evidence(merge_plan, result)
        return evidence if evidence.is_a?(A3::Application::ExecutionResult)

        A3::Application::ExecutionResult.new(
          success: true,
          summary: "agent merged #{merge_plan.merge_source.source_ref} into #{merge_plan.integration_target.target_ref} for #{merge_plan.merge_slots.join(',')}",
          diagnostics: {
            "agent_job_result" => result.result_form,
            "merged_slots" => evidence
          }
        )
      end

      def agent_owned?
        true
      end

      private

      def build_job_request(merge_plan)
        A3::Domain::AgentJobRequest.new(
          job_id: job_id_for(merge_plan),
          project_key: merge_plan.project_key,
          task_ref: merge_plan.task_ref,
          phase: :merge,
          runtime_profile: @runtime_profile,
          source_descriptor: A3::Domain::SourceDescriptor.runtime_detached_commit(
            task_ref: merge_plan.task_ref,
            ref: merge_plan.integration_target.target_ref
          ),
          merge_request: merge_request_form(merge_plan),
          agent_environment: @agent_environment,
          working_dir: ".",
          command: "a2o-agent-merge",
          args: [],
          env: {},
          timeout_seconds: @timeout_seconds,
          artifact_rules: []
        )
      end

      def merge_request_form(merge_plan)
        {
          "workspace_id" => workspace_id_for(merge_plan),
          "task_ref" => merge_plan.task_ref,
          "external_task_id" => merge_plan.external_task_id,
          "policy" => merge_plan.merge_policy.to_s,
          "delivery" => delivery_request_form(merge_plan.delivery_config),
          "slots" => merge_plan.merge_slots.each_with_object({}) do |slot_name, slots|
            alias_name = @source_aliases.fetch(slot_name) do
              raise A3::Domain::ConfigurationError, "missing agent source alias for merge slot #{slot_name}"
            end
            slots[slot_name.to_s] = {
              "source" => {
                "kind" => "local_git",
                "alias" => alias_name
              },
              "source_ref" => merge_plan.merge_source.source_ref,
              "target_ref" => merge_plan.integration_target.target_ref,
              "bootstrap_ref" => merge_plan.integration_target.bootstrap_ref
            }.compact
          end
        }.compact
      end

      def delivery_request_form(delivery_config)
        return nil unless delivery_config.remote_branch?

        {
          "mode" => delivery_config.mode.to_s,
          "remote" => delivery_config.remote,
          "base_branch" => delivery_config.base_branch,
          "branch_prefix" => delivery_config.branch_prefix,
          "push" => delivery_config.push,
          "sync" => delivery_config.sync,
          "after_push_command" => delivery_config.after_push_command
        }
      end

      def enqueue(request)
        @control_plane_client.enqueue(request)
      rescue StandardError => e
        A3::Application::ExecutionResult.new(
          success: false,
          summary: "agent merge job enqueue failed",
          failing_command: "agent_merge_job_enqueue",
          observed_state: "agent_merge_job_enqueue_failed",
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
          summary: "agent merge job wait timed out",
          failing_command: "agent_merge_job_wait",
          observed_state: "agent_merge_job_wait_timeout",
          diagnostics: {
            "job_id" => job_id,
            "last_state" => last_record&.state&.to_s,
            "control_plane_url" => control_plane_url
          }
        )
      end

      def failed_merge_result(_merge_plan, result, recovery_candidate: nil)
        diagnostics = {
          "agent_job_result" => result.result_form,
          "control_plane_url" => control_plane_url
        }
        response_bundle = {
          "agent_job_result" => result.result_form
        }
        observed_state = result.status.to_s
        if recovery_candidate
          diagnostics["merge_recovery"] = recovery_candidate
          response_bundle["merge_recovery"] = recovery_candidate
          response_bundle["merge_recovery_required"] = true
          observed_state = "merge_recovery_candidate"
        end

        A3::Application::ExecutionResult.new(
          success: false,
          summary: result.summary,
          failing_command: "agent_merge_job",
          observed_state: observed_state,
          diagnostics: diagnostics,
          response_bundle: response_bundle
        )
      end

      def run_merge_recovery(merge_plan, recovery_candidate, merge_result)
        worker_request = build_merge_recovery_worker_request(merge_plan, recovery_candidate)
        worker_record = enqueue(worker_request)
        return recovery_infra_failure_result(merge_result, worker_record, recovery_candidate, "worker_enqueue") if worker_record.is_a?(A3::Application::ExecutionResult)

        worker_completed = wait_for_completion(worker_request.job_id)
        return recovery_infra_failure_result(merge_result, worker_completed, recovery_candidate, "worker_wait") if worker_completed.is_a?(A3::Application::ExecutionResult)

        worker_result = worker_completed.result
        return failed_recovery_result(merge_result, worker_result, recovery_candidate, "worker") unless worker_result.succeeded?

        finalizer_request = build_merge_recovery_finalizer_request(merge_plan, recovery_candidate)
        finalizer_record = enqueue(finalizer_request)
        return recovery_infra_failure_result(merge_result, finalizer_record, recovery_candidate, "finalizer_enqueue") if finalizer_record.is_a?(A3::Application::ExecutionResult)

        finalizer_completed = wait_for_completion(finalizer_request.job_id)
        return recovery_infra_failure_result(merge_result, finalizer_completed, recovery_candidate, "finalizer_wait") if finalizer_completed.is_a?(A3::Application::ExecutionResult)

        finalizer_result = finalizer_completed.result
        return failed_recovery_result(merge_result, finalizer_result, recovery_candidate, "finalizer") unless finalizer_result.succeeded?

        evidence = validate_merge_recovery_evidence(recovery_candidate, worker_result, finalizer_result)
        return evidence if evidence.is_a?(A3::Application::ExecutionResult)

        A3::Application::ExecutionResult.new(
          success: true,
          summary: "agent recovered merge #{merge_plan.merge_source.source_ref} into #{merge_plan.integration_target.target_ref} for #{merge_plan.merge_slots.join(',')}",
          diagnostics: {
            "agent_job_result" => merge_result.result_form,
            "merge_recovery" => evidence,
            "merge_recovery_worker_result" => worker_result.result_form,
            "merge_recovery_finalizer_result" => finalizer_result.result_form
          },
          response_bundle: {
            "merge_recovery" => evidence,
            "merge_recovery_required" => false,
            "merge_recovery_verification_required" => true,
            "merge_recovery_verification_source_ref" => evidence.fetch("target_ref")
          }
        )
      end

      def build_merge_recovery_worker_request(merge_plan, recovery_candidate)
        working_dir = first_recovery_runtime_path(recovery_candidate) || "."
        A3::Domain::AgentJobRequest.new(
          job_id: recovery_worker_job_id_for(merge_plan),
          project_key: merge_plan.project_key,
          task_ref: merge_plan.task_ref,
          phase: :merge,
          runtime_profile: @runtime_profile,
          source_descriptor: A3::Domain::SourceDescriptor.runtime_detached_commit(
            task_ref: merge_plan.task_ref,
            ref: merge_plan.integration_target.target_ref
          ),
          agent_environment: @agent_environment,
          working_dir: working_dir,
          command: @merge_recovery_command,
          args: @merge_recovery_args,
          env: workspace_automation_env(working_dir).merge(@merge_recovery_env).merge("A3_MERGE_RECOVERY" => JSON.generate(recovery_candidate)),
          timeout_seconds: @timeout_seconds,
          artifact_rules: []
        )
      end

      def build_merge_recovery_finalizer_request(merge_plan, recovery_candidate)
        A3::Domain::AgentJobRequest.new(
          job_id: recovery_finalizer_job_id_for(merge_plan),
          project_key: merge_plan.project_key,
          task_ref: merge_plan.task_ref,
          phase: :merge,
          runtime_profile: @runtime_profile,
          source_descriptor: A3::Domain::SourceDescriptor.runtime_detached_commit(
            task_ref: merge_plan.task_ref,
            ref: merge_plan.integration_target.target_ref
          ),
          merge_recovery_request: merge_recovery_request_form(merge_plan, recovery_candidate),
          agent_environment: @agent_environment,
          working_dir: ".",
          command: "a2o-agent-merge-recovery",
          args: [],
          env: {},
          timeout_seconds: @timeout_seconds,
          artifact_rules: []
        )
      end

      def merge_recovery_request_form(merge_plan, recovery_candidate)
        {
          "workspace_id" => recovery_candidate.fetch("recovery_id"),
          "slots" => recovery_candidate.fetch("slots").each_with_object({}) do |slot, slots|
            slots[slot.fetch("slot")] = {
              "runtime_path" => slot.fetch("runtime_path"),
              "target_ref" => slot.fetch("target_ref"),
              "source_ref" => slot.fetch("source_ref"),
              "merge_before_head" => slot.fetch("merge_before_head"),
              "source_head_commit" => slot.fetch("source_head_commit"),
              "conflict_files" => Array(slot.fetch("conflict_files")),
              "commit_message" => "A2O merge recovery #{merge_plan.task_ref} #{merge_plan.run_ref}"
            }
          end
        }
      end

      def failed_recovery_result(merge_result, recovery_result, recovery_candidate, stage)
        recovery = recovery_candidate.merge(
          "worker_result_ref" => stage == "worker" ? recovery_result.job_id : recovery_candidate["worker_result_ref"],
          "status" => "recovery_#{stage}_failed"
        )
        A3::Application::ExecutionResult.new(
          success: false,
          summary: recovery_result.summary,
          failing_command: "agent_merge_recovery_#{stage}",
          observed_state: "merge_recovery_#{stage}_failed",
          diagnostics: {
            "agent_job_result" => merge_result.result_form,
            "merge_recovery" => recovery,
            "merge_recovery_#{stage}_result" => recovery_result.result_form,
            "control_plane_url" => control_plane_url
          },
          response_bundle: {
            "merge_recovery" => recovery,
            "merge_recovery_required" => true
          }
        )
      end

      def workspace_automation_env(workspace_root)
        return {} if workspace_root.to_s.empty? || workspace_root == "."

        {
          "AUTOMATION_ISSUE_WORKSPACE" => workspace_root
        }
      end

      def recovery_infra_failure_result(merge_result, infra_result, recovery_candidate, stage)
        recovery = recovery_candidate.merge("status" => "recovery_#{stage}_failed")
        A3::Application::ExecutionResult.new(
          success: false,
          summary: infra_result.summary,
          failing_command: "agent_merge_recovery_#{stage}",
          observed_state: "merge_recovery_candidate",
          diagnostics: {
            "agent_job_result" => merge_result.result_form,
            "merge_recovery" => recovery,
            "merge_recovery_infra_failure" => infra_result.diagnostics,
            "control_plane_url" => control_plane_url
          },
          response_bundle: {
            "merge_recovery" => recovery,
            "merge_recovery_required" => true
          }
        )
      end

      def validate_merge_recovery_evidence(recovery_candidate, worker_result, finalizer_result)
        errors = []
        descriptors = finalizer_result.workspace_descriptor&.slot_descriptors || {}
        expected_slots = recovery_candidate.fetch("slots").map { |slot| slot.fetch("slot") }.sort
        actual_slots = descriptors.keys.sort
        errors << "slot descriptors must match merge recovery slots" unless actual_slots == expected_slots

        enriched_slots = recovery_candidate.fetch("slots").map do |slot|
          slot_name = slot.fetch("slot")
          descriptor = descriptors[slot_name] || {}
          conflict_files = Array(slot.fetch("conflict_files")).map(&:to_s).sort
          changed_files = Array(descriptor["changed_files"]).map(&:to_s).sort
          resolved_conflict_files = Array(descriptor["resolved_conflict_files"]).map(&:to_s).sort
          marker_scan_result = descriptor["marker_scan_result"]
          publish_after_head = descriptor["publish_after_head"]
          merge_after_head = descriptor["merge_after_head"]
          resolved_head = descriptor["resolved_head"]
          errors << "#{slot_name}.merge_status must be recovered" unless descriptor["merge_status"] == "recovered"
          errors << "#{slot_name}.publish_before_head must match merge_before_head" unless descriptor["publish_before_head"] == slot.fetch("merge_before_head")
          errors << "#{slot_name}.publish_after_head must be present" unless present_string?(publish_after_head)
          errors << "#{slot_name}.merge_after_head must match publish_after_head" unless present_string?(publish_after_head) && merge_after_head == publish_after_head
          errors << "#{slot_name}.resolved_head must match publish_after_head" unless present_string?(publish_after_head) && resolved_head == publish_after_head
          errors << "#{slot_name}.resolved_conflict_files must be within conflict_files" unless (resolved_conflict_files - conflict_files).empty?
          errors << "#{slot_name}.changed_files must be within conflict_files" unless (changed_files - conflict_files).empty?
          errors << "#{slot_name}.changed_files must not be empty" if changed_files.empty?
          errors << "#{slot_name}.marker_scan_result must report no unresolved files" unless marker_scan_clean?(marker_scan_result)
          slot.merge(
            "resolved_conflict_files" => resolved_conflict_files,
            "changed_files" => changed_files,
            "publish_before_head" => descriptor["publish_before_head"],
            "publish_after_head" => descriptor["publish_after_head"],
            "merge_after_head" => descriptor["merge_after_head"],
            "resolved_head" => descriptor["resolved_head"],
            "marker_scan_result" => marker_scan_result
          )
        end
        return invalid_merge_recovery_evidence(errors, recovery_candidate, worker_result, finalizer_result) unless errors.empty?

        recovery_candidate.merge(
          "worker_result_ref" => worker_result.job_id,
          "changed_files" => enriched_slots.flat_map { |slot| Array(slot["changed_files"]) }.uniq.sort,
          "marker_scan_result" => enriched_slots.each_with_object({}) { |slot, scan| scan[slot.fetch("slot")] = slot["marker_scan_result"] },
          "publish_before_head" => enriched_slots.map { |slot| slot["publish_before_head"] }.compact.first,
          "publish_after_head" => enriched_slots.map { |slot| slot["publish_after_head"] }.compact.first,
          "resolved_conflict_files" => enriched_slots.flat_map { |slot| Array(slot["resolved_conflict_files"]) }.uniq.sort,
          "status" => "recovered",
          "slots" => enriched_slots
        )
      end

      def invalid_merge_recovery_evidence(errors, recovery_candidate, worker_result, finalizer_result)
        A3::Application::ExecutionResult.new(
          success: false,
          summary: "agent merge recovery evidence is invalid",
          failing_command: "agent_merge_recovery_evidence",
          observed_state: "merge_recovery_evidence_invalid",
          diagnostics: {
            "validation_errors" => errors,
            "merge_recovery" => recovery_candidate,
            "merge_recovery_worker_result" => worker_result.result_form,
            "merge_recovery_finalizer_result" => finalizer_result.result_form,
            "control_plane_url" => control_plane_url
          }
        )
      end

      def merge_recovery_candidate(merge_plan, result)
        descriptors = result.workspace_descriptor&.slot_descriptors || {}
        candidate_slots = descriptors.each_with_object([]) do |(slot_name, descriptor), slots|
          next unless descriptor["merge_recovery_candidate"] == true

          slots << {
            "slot" => slot_name.to_s,
            "runtime_path" => descriptor["runtime_path"],
            "target_ref" => descriptor["merge_target_ref"],
            "source_ref" => descriptor["merge_source_ref"],
            "merge_before_head" => descriptor["merge_before_head"],
            "source_head_commit" => descriptor["source_head_commit"],
            "conflict_files" => Array(descriptor["conflict_files"]).map(&:to_s),
            "resolved_conflict_files" => Array(descriptor["resolved_conflict_files"]).map(&:to_s)
          }
        end
        return nil if candidate_slots.empty?

        {
          "required" => true,
          "recovery_id" => "merge-recovery-#{safe_id(result.job_id)}",
          "merge_run_ref" => merge_plan.run_ref,
          "target_ref" => merge_plan.integration_target.target_ref,
          "source_ref" => merge_plan.merge_source.source_ref,
          "merge_before_head" => candidate_slots.map { |slot| slot["merge_before_head"] }.compact.first,
          "source_head_commit" => candidate_slots.map { |slot| slot["source_head_commit"] }.compact.first,
          "conflict_files" => candidate_slots.flat_map { |slot| Array(slot["conflict_files"]) }.uniq.sort,
          "resolved_conflict_files" => candidate_slots.flat_map { |slot| Array(slot["resolved_conflict_files"]) }.uniq.sort,
          "worker_result_ref" => nil,
          "changed_files" => [],
          "marker_scan_result" => nil,
          "verification_run_ref" => nil,
          "publish_before_head" => nil,
          "publish_after_head" => nil,
          "status" => result.status.to_s,
          "slots" => candidate_slots
        }
      end

      def validate_merge_evidence(merge_plan, result)
        errors = []
        merged_slots = []
        descriptors = result.workspace_descriptor.slot_descriptors
        expected_slots = merge_plan.merge_slots.map(&:to_s).sort
        actual_slots = descriptors.keys.sort
        errors << "workspace_id must match merge request" unless result.workspace_descriptor.workspace_id == workspace_id_for(merge_plan)
        errors << "slot descriptors must match merge slots" unless actual_slots == expected_slots
        merge_plan.merge_slots.each do |slot_name|
          descriptor = descriptors[slot_name.to_s]
          if descriptor.nil?
            errors << "#{slot_name}.merge descriptor is missing"
            next
          end
          expected_alias = @source_aliases.fetch(slot_name.to_sym).to_s
          expected_runtime_path_fragment = File.join(workspace_id_for(merge_plan), slot_name.to_s)
          errors << "#{slot_name}.source_alias must match configured agent source alias" unless descriptor["source_alias"] == expected_alias
          errors << "#{slot_name}.runtime_path must identify the agent merge workspace" unless descriptor["runtime_path"].to_s.include?(expected_runtime_path_fragment)
          errors << "#{slot_name}.merge_source_ref must match merge plan" unless descriptor["merge_source_ref"] == merge_plan.merge_source.source_ref
          errors << "#{slot_name}.merge_target_ref must match merge plan" unless descriptor["merge_target_ref"] == merge_plan.integration_target.target_ref
          errors << "#{slot_name}.merge_policy must match merge plan" unless descriptor["merge_policy"] == merge_plan.merge_policy.to_s
          errors << "#{slot_name}.merge_status must be merged" unless descriptor["merge_status"] == "merged"
          if merge_plan.delivery_config.remote_branch? && merge_plan.delivery_config.push
            errors << "#{slot_name}.delivery_mode must be remote_branch" unless descriptor["delivery_mode"] == "remote_branch"
            errors << "#{slot_name}.push_status must be pushed" unless descriptor["push_status"] == "pushed"
            errors << "#{slot_name}.remote must match delivery config" unless descriptor["remote"] == merge_plan.delivery_config.remote
            errors << "#{slot_name}.pushed_ref must match merge plan" unless descriptor["pushed_ref"] == merge_plan.integration_target.target_ref
            errors << "#{slot_name}.push_commit must match merge_after_head" unless descriptor["push_commit"] == descriptor["merge_after_head"]
            if merge_plan.delivery_config.after_push_command
              errors << "#{slot_name}.after_push_status must be succeeded" unless descriptor["after_push_status"] == "succeeded"
            end
          end
          errors << "#{slot_name}.merge_before_head must be present" unless present_string?(descriptor["merge_before_head"])
          errors << "#{slot_name}.merge_after_head must be present" unless present_string?(descriptor["merge_after_head"])
          errors << "#{slot_name}.resolved_head must match merge_after_head" unless descriptor["resolved_head"] == descriptor["merge_after_head"]
          unless descriptor["project_repo_mutator"] == "a2o-agent"
            errors << "#{slot_name}.project_repo_mutator must be a2o-agent"
          end
          merged_slots << {
            "slot" => slot_name.to_s,
            "target_ref" => descriptor["merge_target_ref"],
            "before_head" => descriptor["merge_before_head"],
            "after_head" => descriptor["merge_after_head"]
          }
        end
        return merged_slots if errors.empty?

        A3::Application::ExecutionResult.new(
          success: false,
          summary: "agent merge evidence is invalid",
          failing_command: "agent_merge_evidence",
          observed_state: "agent_merge_evidence_invalid",
          diagnostics: {
            "validation_errors" => errors,
            "agent_job_result" => result.result_form,
            "control_plane_url" => control_plane_url
          }
        )
      end

      def workspace_id_for(merge_plan)
        "merge-#{safe_id(merge_plan.task_ref)}-#{safe_id(merge_plan.run_ref)}"
      end

      def job_id_for(merge_plan)
        "merge-#{safe_id(merge_plan.run_ref)}-#{safe_id(@job_id_generator.call)}"
      end

      def recovery_worker_job_id_for(merge_plan)
        "merge-recovery-worker-#{safe_id(merge_plan.run_ref)}-#{safe_id(@job_id_generator.call)}"
      end

      def recovery_finalizer_job_id_for(merge_plan)
        "merge-recovery-finalizer-#{safe_id(merge_plan.run_ref)}-#{safe_id(@job_id_generator.call)}"
      end

      def marker_scan_clean?(marker_scan_result)
        return false unless marker_scan_result.is_a?(Hash)
        valid_scanners = %w[
          a2o-agent-conflict-marker-scan
        ]
        return false unless valid_scanners.include?(marker_scan_result["scanner"])

        unresolved = marker_scan_result["unresolved_files"]
        unresolved.is_a?(Array) && unresolved.empty?
      end

      def first_recovery_runtime_path(recovery_candidate)
        recovery_candidate.fetch("slots").map { |slot| slot["runtime_path"] }.find { |path| present_string?(path) }
      end

      def merge_recovery_enabled?
        present_string?(@merge_recovery_command)
      end

      def present_string?(value)
        value.is_a?(String) && !value.empty?
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
