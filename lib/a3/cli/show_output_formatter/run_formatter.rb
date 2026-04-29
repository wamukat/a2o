# frozen_string_literal: true

require "time"

module A3
  module CLI
    module ShowOutputFormatter
      module RunFormatter
        module_function

        def lines(run)
          [].tap do |result|
            result << "run #{run.ref} task=#{run.task_ref} phase=#{run.phase} workspace=#{run.workspace_kind} source=#{run.source_type}:#{run.source_ref} outcome=#{run.terminal_outcome}"
            if run.workspace_kind.to_sym == :runtime_workspace
              result << "workspace_model=runtime_workspace is a logical phase workspace kind; inspect runtime_package_materialization_model for physical isolation"
            end
            append_recovery_lines(result, run.recovery)
            append_evidence_lines(result, run.evidence_summary)
            append_latest_execution_lines(result, run.latest_execution)
            append_latest_blocked_lines(result, run.latest_blocked_diagnosis)
            result << "phase_records=#{run.evidence_summary.phase_records_count}"
          end
        end

        def append_recovery_lines(result, recovery)
          return unless recovery

          result << "recovery decision=#{recovery.decision} next_action=#{recovery.next_action} operator_action_required=#{recovery.operator_action_required}"
          result << "runtime_package_action=#{recovery.package_expectation}"
          result << "runtime_package_guidance=#{recovery.runtime_package_guidance}" if recovery.runtime_package_guidance
          result << "runtime_package_contract_health=#{recovery.runtime_package_contract_health}" if recovery.runtime_package_contract_health
          result << "runtime_package_execution_modes=#{recovery.runtime_package_execution_modes}" if recovery.runtime_package_execution_modes
          result << "runtime_package_execution_mode_contract=#{recovery.runtime_package_execution_mode_contract}" if recovery.runtime_package_execution_mode_contract
          result << "runtime_package_schema_action=#{recovery.runtime_package_schema_action}" if recovery.runtime_package_schema_action
          result << "runtime_package_preset_schema_action=#{recovery.runtime_package_preset_schema_action}" if recovery.runtime_package_preset_schema_action
          result << "runtime_package_repo_source_action=#{recovery.runtime_package_repo_source_action}" if recovery.runtime_package_repo_source_action
          result << "runtime_package_secret_delivery_action=#{recovery.runtime_package_secret_delivery_action}" if recovery.runtime_package_secret_delivery_action
          result << "runtime_package_scheduler_store_migration_action=#{recovery.runtime_package_scheduler_store_migration_action}" if recovery.runtime_package_scheduler_store_migration_action
          result << "runtime_package_recommended_execution_mode=#{recovery.runtime_package_recommended_execution_mode}" if recovery.runtime_package_recommended_execution_mode
          result << "runtime_package_recommended_execution_mode_reason=#{recovery.runtime_package_recommended_execution_mode_reason}" if recovery.runtime_package_recommended_execution_mode_reason
          result << "runtime_package_recommended_execution_mode_command=#{recovery.runtime_package_recommended_execution_mode_command}"
          result << "runtime_package_operator_action=#{recovery.runtime_package_operator_action}"
          result << "runtime_package_operator_action_command=#{recovery.runtime_package_operator_action_command}"
          result << "runtime_package_next_execution_mode=#{recovery.runtime_package_next_execution_mode}"
          result << "runtime_package_next_execution_mode_reason=#{recovery.runtime_package_next_execution_mode_reason}"
          result << "runtime_package_next_execution_mode_command=#{recovery.runtime_package_next_execution_mode_command}"
          result << "runtime_package_next_command=#{recovery.runtime_package_next_command}" if recovery.runtime_package_next_command
          result << "runtime_package_doctor_command=#{recovery.runtime_package_doctor_command}" if recovery.runtime_package_doctor_command
          result << "runtime_package_migration_command=#{recovery.runtime_package_migration_command}" if recovery.runtime_package_migration_command
          result << "runtime_package_runtime_command=#{recovery.runtime_package_runtime_command}" if recovery.runtime_package_runtime_command
          result << "runtime_package_runtime_validation_command=#{recovery.runtime_package_runtime_validation_command}" if recovery.runtime_package_runtime_validation_command
          result << "runtime_package_startup_sequence=#{recovery.runtime_package_startup_sequence}" if recovery.runtime_package_startup_sequence
          result << "runtime_package_startup_blockers=#{recovery.runtime_package_startup_blockers}" if recovery.runtime_package_startup_blockers
          result << "runtime_package_persistent_state_model=#{recovery.runtime_package_persistent_state_model}" if recovery.runtime_package_persistent_state_model
          result << "runtime_package_retention_policy=#{recovery.runtime_package_retention_policy}" if recovery.runtime_package_retention_policy
          result << "runtime_package_materialization_model=#{recovery.runtime_package_materialization_model}" if recovery.runtime_package_materialization_model
          result << "runtime_package_runtime_configuration_model=#{recovery.runtime_package_runtime_configuration_model}" if recovery.runtime_package_runtime_configuration_model
          result << "runtime_package_repository_metadata_model=#{recovery.runtime_package_repository_metadata_model}" if recovery.runtime_package_repository_metadata_model
          result << "runtime_package_branch_resolution_model=#{recovery.runtime_package_branch_resolution_model}" if recovery.runtime_package_branch_resolution_model
          result << "runtime_package_credential_boundary_model=#{recovery.runtime_package_credential_boundary_model}" if recovery.runtime_package_credential_boundary_model
          result << "runtime_package_observability_boundary_model=#{recovery.runtime_package_observability_boundary_model}" if recovery.runtime_package_observability_boundary_model
          result << "runtime_package_deployment_shape=#{recovery.runtime_package_deployment_shape}" if recovery.runtime_package_deployment_shape
          result << "runtime_package_networking_boundary=#{recovery.runtime_package_networking_boundary}" if recovery.runtime_package_networking_boundary
          result << "runtime_package_upgrade_contract=#{recovery.runtime_package_upgrade_contract}" if recovery.runtime_package_upgrade_contract
          result << "runtime_package_fail_fast_policy=#{recovery.runtime_package_fail_fast_policy}" if recovery.runtime_package_fail_fast_policy
          result << "rerun_hint=#{recovery.rerun_hint}" if recovery.rerun_hint
        end

        def append_evidence_lines(result, summary)
          if summary.review_base && summary.review_head
            result << "review_target=#{summary.review_base}..#{summary.review_head}"
          end
          result << "edit_scope=#{summary.edit_scope.join(',')}"
          result << "verification_scope=#{summary.verification_scope.join(',')}"
          result << "ownership_scope=#{summary.ownership_scope}"
          if summary.artifact_owner_ref
            result << "artifact_owner=#{summary.artifact_owner_ref} (#{summary.artifact_owner_scope}) snapshot=#{summary.artifact_snapshot_version}"
          end
        end

        def append_latest_execution_lines(result, execution)
          return unless execution

          result << "latest_execution phase=#{execution.phase} summary=#{execution.summary}"
          append_agent_job_timing_lines(result, execution.diagnostics)
          result << "verification_summary=#{execution.verification_summary}" if execution.verification_summary
          append_review_disposition_lines(result, execution.review_disposition)
          append_clarification_request_lines(result, execution.clarification_request)
          append_skill_feedback_lines(result, execution.skill_feedback)
          append_inherited_parent_lines(result, execution.diagnostics)
          append_project_prompt_lines(result, execution.diagnostics)
          append_validation_error_lines(result, "execution_validation_error", execution.diagnostics)
          result << "failing_command=#{FormattingHelpers.diagnostic_value(execution.failing_command)}" if execution.failing_command
          result << "observed_state=#{execution.observed_state}" if execution.observed_state
          result << "worker_response_bundle=#{FormattingHelpers.diagnostic_value(execution.worker_response_bundle)}" if execution.worker_response_bundle
          append_agent_artifact_lines(result, execution.agent_artifacts)
          append_merge_recovery_lines(result, execution.merge_recovery)
          public_diagnostics(execution.diagnostics).sort.each do |key, value|
            result << "execution_diagnostic.#{key}=#{FormattingHelpers.diagnostic_value(value)}"
          end
          append_runtime_lines(result, execution.runtime_snapshot)
        end

        def public_diagnostics(diagnostics)
          diagnostics.reject do |key, _|
            %w[
              merge_recovery
              agent_job_result
              agent_artifacts
              control_plane_url
              inherited_parent_ref
              inherited_parent_state_fingerprint
              project_prompt
            ].include?(key)
          end
        end

        def append_project_prompt_lines(result, diagnostics)
          prompt = diagnostics["project_prompt"]
          return unless prompt.is_a?(Hash)

          result << "project_prompt profile=#{prompt['profile']} composed_sha256=#{prompt['composed_instruction_sha256']} bytes=#{prompt['composed_instruction_bytes']}"
          Array(prompt["layers"]).each do |layer|
            next unless layer.is_a?(Hash)

            result << "project_prompt_layer kind=#{layer['kind']} title=#{layer['title']} sha256=#{layer['content_sha256']} bytes=#{layer['content_bytes']}"
          end
        end

        def append_agent_artifact_lines(result, artifacts)
          Array(artifacts).each do |artifact|
            next unless artifact.is_a?(Hash)

            artifact_id = artifact["artifact_id"]
            next if artifact_id.to_s.empty?

            role = artifact["role"] || "artifact"
            retention = artifact["retention_class"] || "unknown"
            media_type = artifact["media_type"] || "application/octet-stream"
            byte_size = artifact["byte_size"] || "unknown"
            result << "agent_artifact role=#{role} id=#{artifact_id} retention=#{retention} media_type=#{media_type} byte_size=#{byte_size}"
            result << "agent_artifact_read=a2o runtime show-artifact #{artifact_id}"
          end
        end

        def append_merge_recovery_lines(result, merge_recovery)
          return unless merge_recovery.is_a?(Hash)

          result << "merge_recovery status=#{merge_recovery['status']} target_ref=#{merge_recovery['target_ref']} source_ref=#{merge_recovery['source_ref']}"
          result << "merge_recovery_worker_result_ref=#{merge_recovery['worker_result_ref']}" if merge_recovery['worker_result_ref']
          result << "merge_recovery_publish=#{merge_recovery['publish_before_head']}..#{merge_recovery['publish_after_head']}" if merge_recovery['publish_before_head'] || merge_recovery['publish_after_head']
          conflict_files = Array(merge_recovery['conflict_files'])
          result << "merge_recovery_conflict_files=#{conflict_files.join(',')}" unless conflict_files.empty?
          changed_files = Array(merge_recovery['changed_files'])
          result << "merge_recovery_changed_files=#{changed_files.join(',')}" unless changed_files.empty?
        end

        def append_runtime_lines(result, runtime)
          return unless runtime

          result << "runtime task_kind=#{runtime.task_kind} repo_scope=#{runtime.repo_scope} phase=#{runtime.phase}"
          result << "runtime implementation_skill=#{runtime.implementation_skill}" if runtime.implementation_skill
          result << "runtime review_skill=#{runtime.review_skill}" if runtime.review_skill
          result << "runtime verification_commands=#{runtime.verification_commands.join(' ')}" unless runtime.verification_commands.empty?
          result << "runtime remediation_commands=#{runtime.remediation_commands.join(' ')}" unless runtime.remediation_commands.empty?
          result << "runtime workspace_hook=#{runtime.workspace_hook}" if runtime.workspace_hook
          result << "runtime merge_target=#{runtime.merge_target} merge_policy=#{runtime.merge_policy}"
        end

        def append_review_disposition_lines(result, review_disposition)
          return unless review_disposition.is_a?(Hash)

          result << "review_disposition kind=#{review_disposition['kind']} repo_scope=#{review_disposition['repo_scope']} finding_key=#{review_disposition['finding_key']}"
          result << "review_disposition_summary=#{review_disposition['summary']}" if review_disposition["summary"]
          result << "review_disposition_description=#{review_disposition['description']}" if review_disposition["description"]
        end

        def append_clarification_request_lines(result, request)
          return unless request.is_a?(Hash)

          result << "clarification_question=#{request['question']}" if request["question"]
          result << "clarification_context=#{request['context']}" if request["context"]
          options = Array(request["options"]).reject { |option| option.to_s.strip.empty? }
          result << "clarification_options=#{options.join(' | ')}" unless options.empty?
          result << "clarification_recommended_option=#{request['recommended_option']}" if request["recommended_option"]
          result << "clarification_impact=#{request['impact']}" if request["impact"]
        end

        def append_skill_feedback_lines(result, feedback_entries)
          entries = Array(feedback_entries).select { |feedback| feedback.is_a?(Hash) }
          return if entries.empty?

          result << "skill_feedback_count=#{entries.size}"
          pending_count = entries.count { |feedback| A3::Domain::SkillFeedback.pending_review?(feedback) }
          if pending_count.positive?
            result << "skill_feedback_pending_review=#{pending_count} action=review_or_convert_to_ticket"
          end

          entries.each do |feedback|
            next unless feedback.is_a?(Hash)

            proposal = A3::Domain::SkillFeedback.proposal_for(feedback)
            parts = [
              "category=#{FormattingHelpers.diagnostic_value(feedback['category'])}",
              "target=#{FormattingHelpers.diagnostic_value(proposal['target'])}",
              "state=#{FormattingHelpers.diagnostic_value(A3::Domain::SkillFeedback.state_for(feedback))}"
            ]
            parts << "repo_scope=#{FormattingHelpers.diagnostic_value(feedback['repo_scope'])}" if feedback["repo_scope"]
            parts << "skill_path=#{FormattingHelpers.diagnostic_value(feedback['skill_path'])}" if feedback["skill_path"]
            parts << "confidence=#{FormattingHelpers.diagnostic_value(feedback['confidence'])}" if feedback["confidence"]
            result << "skill_feedback #{parts.join(' ')}"
            result << "skill_feedback_summary=#{feedback['summary']}" if feedback["summary"]
            result << "skill_feedback_suggested_patch=#{proposal['suggested_patch']}" if proposal["suggested_patch"]
          end
        end

        def append_latest_blocked_lines(result, diagnosis)
          return unless diagnosis

          result << "latest_blocked phase=#{diagnosis.phase} summary=#{diagnosis.summary}"
          append_inherited_parent_lines(result, diagnosis.infra_diagnostics)
          result << "blocked_error_category=#{diagnosis.error_category}"
          result << "blocked_remediation=#{diagnosis.remediation_summary}"
          result << "blocked_expected=#{diagnosis.expected_state}"
          result << "blocked_observed=#{diagnosis.observed_state}"
          result << "blocked_failing_command=#{FormattingHelpers.diagnostic_value(diagnosis.failing_command)}" if diagnosis.failing_command
          append_validation_error_lines(result, "blocked_validation_error", diagnosis.infra_diagnostics)
          public_diagnostics(diagnosis.infra_diagnostics).sort.each do |key, value|
            result << "blocked_diagnostic.#{key}=#{FormattingHelpers.diagnostic_value(value)}"
          end
        end

        def append_validation_error_lines(result, label, diagnostics)
          Array(validation_errors_from(diagnostics)).each do |error|
            next if error.to_s.strip.empty?

            result << "#{label}=#{FormattingHelpers.diagnostic_value(error)}"
          end
        end

        def validation_errors_from(diagnostics)
          return [] unless diagnostics.is_a?(Hash)

          errors = diagnostics["validation_errors"]
          errors.is_a?(Array) ? errors : []
        end

        def append_inherited_parent_lines(result, diagnostics)
          return unless diagnostics.is_a?(Hash)

          inherited_ref = diagnostics["inherited_parent_ref"]
          inherited_fingerprint = diagnostics["inherited_parent_state_fingerprint"]
          return if inherited_ref.to_s.empty? && inherited_fingerprint.to_s.empty?

          result << "inherited_parent_state ref=#{FormattingHelpers.diagnostic_value(inherited_ref)} fingerprint=#{FormattingHelpers.diagnostic_value(inherited_fingerprint)}"
        end

        def append_agent_job_timing_lines(result, diagnostics)
          return unless diagnostics.is_a?(Hash)

          agent_job_result = diagnostics["agent_job_result"]
          return unless agent_job_result.is_a?(Hash)

          started_at = agent_job_result["started_at"]
          finished_at = agent_job_result["finished_at"]
          return if started_at.to_s.empty? || finished_at.to_s.empty?

          result << "execution_started_at=#{started_at}"
          result << "execution_finished_at=#{finished_at}"
          duration = begin
            Time.iso8601(finished_at) - Time.iso8601(started_at)
          rescue ArgumentError
            nil
          end
          result << format("execution_duration_seconds=%.3f", duration) if duration
        end
      end
    end
  end
end
