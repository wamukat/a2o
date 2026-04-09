# frozen_string_literal: true

module A3
  module Domain
    class OperatorInspectionReadModel
      module RuntimePackageRecoveryAttributes
        module_function

        def for_decision(decision:, doctor_result:)
          attributes_for(decision).merge(
            runtime_package_guidance: doctor_result.operator_guidance,
            runtime_package_contract_health: doctor_result.contract_health,
            runtime_package_execution_modes: doctor_result.execution_modes_summary,
            runtime_package_execution_mode_contract: doctor_result.execution_mode_contract_summary,
            runtime_package_schema_action: doctor_result.schema_action_summary,
            runtime_package_preset_schema_action: doctor_result.preset_schema_action_summary,
            runtime_package_repo_source_action: doctor_result.repo_source_action_summary,
            runtime_package_secret_delivery_action: doctor_result.secret_delivery_action_summary,
            runtime_package_scheduler_store_migration_action: doctor_result.scheduler_store_migration_action_summary,
            runtime_package_recommended_execution_mode: doctor_result.recommended_execution_mode,
            runtime_package_recommended_execution_mode_reason: doctor_result.recommended_execution_mode_reason,
            runtime_package_recommended_execution_mode_command: doctor_result.recommended_execution_mode_command,
            runtime_package_operator_action: operator_action_for(decision),
            runtime_package_operator_action_command: operator_action_command_for(decision, doctor_result),
            runtime_package_next_execution_mode: next_execution_mode_for(decision),
            runtime_package_next_execution_mode_reason: next_execution_mode_reason_for(decision),
            runtime_package_next_execution_mode_command: next_execution_mode_command_for(decision, doctor_result),
            runtime_package_next_command: doctor_result.next_command,
            runtime_package_doctor_command: doctor_result.doctor_command_summary,
            runtime_package_migration_command: doctor_result.migration_command_summary,
            runtime_package_runtime_command: doctor_result.runtime_command_summary,
            runtime_package_runtime_canary_command: doctor_result.runtime_canary_command_summary,
            runtime_package_startup_sequence: doctor_result.startup_sequence,
            runtime_package_startup_blockers: doctor_result.startup_blockers,
            runtime_package_persistent_state_model: doctor_result.distribution_summary.fetch("persistent_state_model"),
            runtime_package_retention_policy: doctor_result.distribution_summary.fetch("retention_policy"),
            runtime_package_materialization_model: doctor_result.distribution_summary.fetch("materialization_model"),
            runtime_package_runtime_configuration_model: doctor_result.distribution_summary.fetch("runtime_configuration_model"),
            runtime_package_repository_metadata_model: doctor_result.distribution_summary.fetch("repository_metadata_model"),
            runtime_package_branch_resolution_model: doctor_result.distribution_summary.fetch("branch_resolution_model"),
            runtime_package_credential_boundary_model: doctor_result.distribution_summary.fetch("credential_boundary_model"),
            runtime_package_observability_boundary_model: doctor_result.distribution_summary.fetch("observability_boundary_model"),
            runtime_package_deployment_shape: doctor_result.distribution_summary.fetch("deployment_shape"),
            runtime_package_networking_boundary: doctor_result.distribution_summary.fetch("networking_boundary"),
            runtime_package_upgrade_contract: doctor_result.distribution_summary.fetch("upgrade_contract"),
            runtime_package_fail_fast_policy: doctor_result.distribution_summary.fetch("fail_fast_policy")
          )
        end

        def attributes_for(decision)
          case decision.to_sym
          when :requires_operator_action
            {
              decision: :requires_operator_action,
              next_action: :diagnose_blocked,
              operator_action_required: true,
              summary: "blocked run requires operator action before rerun",
              rerun_hint: "diagnose blocked state and choose a fresh rerun source",
              package_expectation: :inspect_runtime_package
            }
          when :same_phase_retry
            {
              decision: :same_phase_retry,
              next_action: :retry_current_phase,
              operator_action_required: false,
              summary: "same phase can be retried with the current evidence",
              rerun_hint: "rerun the same phase with the current source and review target",
              package_expectation: :reuse_runtime_package
            }
          when :requires_new_implementation
            {
              decision: :requires_new_implementation,
              next_action: :start_new_implementation,
              operator_action_required: false,
              summary: "a fresh implementation run is required before retrying",
              rerun_hint: "start a new implementation run and regenerate review evidence",
              package_expectation: :refresh_runtime_package
            }
          else
            raise A3::Domain::ConfigurationError, "unsupported recovery decision: #{decision.inspect}"
          end
        end

        def operator_action_for(decision)
          case decision.to_sym
          when :requires_operator_action
            :keep_inspecting
          when :same_phase_retry
            :run_now
          when :requires_new_implementation
            :refresh_runtime_package
          else
            raise A3::Domain::ConfigurationError, "unsupported recovery decision: #{decision.inspect}"
          end
        end

        def next_execution_mode_for(decision)
          case decision.to_sym
          when :requires_operator_action, :requires_new_implementation
            :doctor_inspect
          when :same_phase_retry
            :one_shot_cli
          else
            raise A3::Domain::ConfigurationError, "unsupported recovery decision: #{decision.inspect}"
          end
        end

        def next_execution_mode_reason_for(decision)
          case decision.to_sym
          when :requires_operator_action
            "runtime package still needs inspection before recovery can proceed"
          when :same_phase_retry
            "current evidence is sufficient; rerun through one_shot_cli"
          when :requires_new_implementation
            "refresh runtime package inputs before starting a new implementation run"
          else
            raise A3::Domain::ConfigurationError, "unsupported recovery decision: #{decision.inspect}"
          end
        end

        def next_execution_mode_command_for(decision, doctor_result)
          case decision.to_sym
          when :requires_operator_action, :requires_new_implementation
            doctor_result.doctor_command_summary
          when :same_phase_retry
            doctor_result.recommended_execution_mode_command
          else
            raise A3::Domain::ConfigurationError, "unsupported recovery decision: #{decision.inspect}"
          end
        end

        def operator_action_command_for(decision, doctor_result)
          case decision.to_sym
          when :requires_operator_action, :requires_new_implementation
            doctor_result.doctor_command_summary
          when :same_phase_retry
            doctor_result.recommended_execution_mode_command
          else
            raise A3::Domain::ConfigurationError, "unsupported recovery decision: #{decision.inspect}"
          end
        end
      end
    end
  end
end
