# frozen_string_literal: true

module A3
  module CLI
      module ShowOutputFormatter
      module BlockedDiagnosisFormatter
        module_function

        def lines(result)
          [].tap do |output|
            diagnosis = result.diagnosis
            recovery = result.recovery
            worker_response_bundle = result.worker_response_bundle

            output << "blocked diagnosis #{diagnosis.outcome} for #{result.run.ref} on #{result.task.ref}"
            output << "phase=#{diagnosis.phase} observed=#{diagnosis.observed_state}"
            output << "expected=#{diagnosis.expected_state}"
            output << "failing_command=#{diagnosis.failing_command}"
            output << "summary=#{diagnosis.diagnostic_summary}"
            output << "worker_response_bundle=#{FormattingHelpers.diagnostic_value(worker_response_bundle)}" if worker_response_bundle
            output << "recovery decision=#{recovery.decision} next_action=#{recovery.next_action} operator_action_required=#{recovery.operator_action_required}"
            output << "runtime_package_action=#{recovery.package_expectation}"
            output << "runtime_package_guidance=#{recovery.runtime_package_guidance}" if recovery.runtime_package_guidance
            output << "runtime_package_contract_health=#{recovery.runtime_package_contract_health}" if recovery.runtime_package_contract_health
            output << "runtime_package_execution_modes=#{recovery.runtime_package_execution_modes}" if recovery.runtime_package_execution_modes
            output << "runtime_package_execution_mode_contract=#{recovery.runtime_package_execution_mode_contract}" if recovery.runtime_package_execution_mode_contract
            output << "runtime_package_schema_action=#{recovery.runtime_package_schema_action}" if recovery.runtime_package_schema_action
            output << "runtime_package_preset_schema_action=#{recovery.runtime_package_preset_schema_action}" if recovery.runtime_package_preset_schema_action
            output << "runtime_package_repo_source_action=#{recovery.runtime_package_repo_source_action}" if recovery.runtime_package_repo_source_action
            output << "runtime_package_secret_delivery_action=#{recovery.runtime_package_secret_delivery_action}" if recovery.runtime_package_secret_delivery_action
            output << "runtime_package_scheduler_store_migration_action=#{recovery.runtime_package_scheduler_store_migration_action}" if recovery.runtime_package_scheduler_store_migration_action
            output << "runtime_package_recommended_execution_mode=#{recovery.runtime_package_recommended_execution_mode}" if recovery.runtime_package_recommended_execution_mode
            output << "runtime_package_recommended_execution_mode_reason=#{recovery.runtime_package_recommended_execution_mode_reason}" if recovery.runtime_package_recommended_execution_mode_reason
            output << "runtime_package_recommended_execution_mode_command=#{recovery.runtime_package_recommended_execution_mode_command}"
            output << "runtime_package_operator_action=#{recovery.runtime_package_operator_action}"
            output << "runtime_package_operator_action_command=#{recovery.runtime_package_operator_action_command}"
            output << "runtime_package_next_execution_mode=#{recovery.runtime_package_next_execution_mode}"
            output << "runtime_package_next_execution_mode_reason=#{recovery.runtime_package_next_execution_mode_reason}"
            output << "runtime_package_next_execution_mode_command=#{recovery.runtime_package_next_execution_mode_command}"
            output << "runtime_package_next_command=#{recovery.runtime_package_next_command}" if recovery.runtime_package_next_command
            output << "runtime_package_doctor_command=#{recovery.runtime_package_doctor_command}" if recovery.runtime_package_doctor_command
            output << "runtime_package_migration_command=#{recovery.runtime_package_migration_command}" if recovery.runtime_package_migration_command
            output << "runtime_package_runtime_command=#{recovery.runtime_package_runtime_command}" if recovery.runtime_package_runtime_command
            output << "runtime_package_runtime_canary_command=#{recovery.runtime_package_runtime_canary_command}" if recovery.runtime_package_runtime_canary_command
            output << "runtime_package_startup_sequence=#{recovery.runtime_package_startup_sequence}" if recovery.runtime_package_startup_sequence
            output << "runtime_package_startup_blockers=#{recovery.runtime_package_startup_blockers}" if recovery.runtime_package_startup_blockers
            output << "runtime_package_persistent_state_model=#{recovery.runtime_package_persistent_state_model}" if recovery.runtime_package_persistent_state_model
            output << "runtime_package_retention_policy=#{recovery.runtime_package_retention_policy}" if recovery.runtime_package_retention_policy
            output << "runtime_package_materialization_model=#{recovery.runtime_package_materialization_model}" if recovery.runtime_package_materialization_model
            output << "runtime_package_runtime_configuration_model=#{recovery.runtime_package_runtime_configuration_model}" if recovery.runtime_package_runtime_configuration_model
            output << "runtime_package_repository_metadata_model=#{recovery.runtime_package_repository_metadata_model}" if recovery.runtime_package_repository_metadata_model
            output << "runtime_package_branch_resolution_model=#{recovery.runtime_package_branch_resolution_model}" if recovery.runtime_package_branch_resolution_model
            output << "runtime_package_credential_boundary_model=#{recovery.runtime_package_credential_boundary_model}" if recovery.runtime_package_credential_boundary_model
            output << "runtime_package_observability_boundary_model=#{recovery.runtime_package_observability_boundary_model}" if recovery.runtime_package_observability_boundary_model
            output << "runtime_package_deployment_shape=#{recovery.runtime_package_deployment_shape}" if recovery.runtime_package_deployment_shape
            output << "runtime_package_networking_boundary=#{recovery.runtime_package_networking_boundary}" if recovery.runtime_package_networking_boundary
            output << "runtime_package_upgrade_contract=#{recovery.runtime_package_upgrade_contract}" if recovery.runtime_package_upgrade_contract
            output << "runtime_package_fail_fast_policy=#{recovery.runtime_package_fail_fast_policy}" if recovery.runtime_package_fail_fast_policy
            output << "rerun_hint=#{recovery.rerun_hint}" if recovery.rerun_hint
            if (summary_snapshot = result.evidence_summary)
              output << "evidence workspace=#{summary_snapshot.workspace_kind} source=#{summary_snapshot.source_type}:#{summary_snapshot.source_ref}"
              if summary_snapshot.review_base && summary_snapshot.review_head
                output << "review_target=#{summary_snapshot.review_base}..#{summary_snapshot.review_head}"
              end
              output << "edit_scope=#{summary_snapshot.edit_scope.join(',')}"
              output << "verification_scope=#{summary_snapshot.verification_scope.join(',')}"
              output << "ownership_scope=#{summary_snapshot.ownership_scope}"
              if summary_snapshot.artifact_owner_ref
                output << "artifact_owner=#{summary_snapshot.artifact_owner_ref} (#{summary_snapshot.artifact_owner_scope}) snapshot=#{summary_snapshot.artifact_snapshot_version}"
              end
              output << "phase_records=#{summary_snapshot.phase_records_count}"
            end
            diagnosis.infra_diagnostics.sort.each do |key, value|
              output << "diagnostic.#{key}=#{FormattingHelpers.diagnostic_value(value)}"
            end
          end
        end
      end
    end
  end
end
