# frozen_string_literal: true

require "securerandom"

module A3
  module Infra
    class AgentMergeRunner
      def initialize(control_plane_client:, runtime_profile:, source_aliases:, timeout_seconds: 1800, poll_interval_seconds: 1.0, job_id_generator: -> { SecureRandom.uuid }, sleeper: ->(seconds) { sleep(seconds) }, monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, agent_environment: nil)
        @control_plane_client = control_plane_client
        @runtime_profile = runtime_profile.to_s
        @source_aliases = source_aliases.transform_keys(&:to_sym).transform_values(&:to_s).freeze
        @timeout_seconds = Integer(timeout_seconds)
        @poll_interval_seconds = Float(poll_interval_seconds)
        @job_id_generator = job_id_generator
        @sleeper = sleeper
        @monotonic_clock = monotonic_clock
        @agent_environment = agent_environment
      end

      def run(merge_plan, workspace:)
        workspace
        request = build_job_request(merge_plan)
        record = enqueue(request)
        return record if record.is_a?(A3::Application::ExecutionResult)

        completed = wait_for_completion(request.job_id)
        return completed if completed.is_a?(A3::Application::ExecutionResult)

        result = completed.result
        return failed_merge_result(merge_plan, result) unless result.succeeded?

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
          command: "a3-agent-merge",
          args: [],
          env: {},
          timeout_seconds: @timeout_seconds,
          artifact_rules: []
        )
      end

      def merge_request_form(merge_plan)
        {
          "workspace_id" => workspace_id_for(merge_plan),
          "policy" => merge_plan.merge_policy.to_s,
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

      def failed_merge_result(merge_plan, result)
        recovery_candidate = merge_recovery_candidate(merge_plan, result)
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
          expected_runtime_path_fragment = File.join(workspace_id_for(merge_plan), slot_name.to_s.tr("_", "-"))
          errors << "#{slot_name}.source_alias must match configured agent source alias" unless descriptor["source_alias"] == expected_alias
          errors << "#{slot_name}.runtime_path must identify the agent merge workspace" unless descriptor["runtime_path"].to_s.include?(expected_runtime_path_fragment)
          errors << "#{slot_name}.merge_source_ref must match merge plan" unless descriptor["merge_source_ref"] == merge_plan.merge_source.source_ref
          errors << "#{slot_name}.merge_target_ref must match merge plan" unless descriptor["merge_target_ref"] == merge_plan.integration_target.target_ref
          errors << "#{slot_name}.merge_policy must match merge plan" unless descriptor["merge_policy"] == merge_plan.merge_policy.to_s
          errors << "#{slot_name}.merge_status must be merged" unless descriptor["merge_status"] == "merged"
          errors << "#{slot_name}.merge_before_head must be present" unless present_string?(descriptor["merge_before_head"])
          errors << "#{slot_name}.merge_after_head must be present" unless present_string?(descriptor["merge_after_head"])
          errors << "#{slot_name}.resolved_head must match merge_after_head" unless descriptor["resolved_head"] == descriptor["merge_after_head"]
          errors << "#{slot_name}.project_repo_mutator must be a3-agent" unless descriptor["project_repo_mutator"] == "a3-agent"
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
