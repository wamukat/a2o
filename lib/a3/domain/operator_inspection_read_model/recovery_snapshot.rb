# frozen_string_literal: true

module A3
  module Domain
    class OperatorInspectionReadModel
      class RecoverySnapshot
        attr_reader :decision, :next_action, :operator_action_required, :summary, :rerun_hint, :package_expectation,
                    :runtime_package_guidance, :runtime_package_contract_health, :runtime_package_execution_modes, :runtime_package_execution_mode_contract,
                    :runtime_package_schema_action, :runtime_package_preset_schema_action, :runtime_package_repo_source_action,
                    :runtime_package_secret_delivery_action, :runtime_package_scheduler_store_migration_action,
                    :runtime_package_recommended_execution_mode, :runtime_package_recommended_execution_mode_reason,
                    :runtime_package_recommended_execution_mode_command,
                    :runtime_package_operator_action, :runtime_package_next_execution_mode,
                    :runtime_package_operator_action_command,
                    :runtime_package_next_execution_mode_reason, :runtime_package_next_execution_mode_command,
                    :runtime_package_next_command, :runtime_package_doctor_command,
                    :runtime_package_runtime_validation_command, :runtime_package_startup_blockers, :runtime_package_migration_command,
                    :runtime_package_runtime_command,
                    :runtime_package_startup_sequence, :runtime_package_persistent_state_model, :runtime_package_retention_policy,
                    :runtime_package_materialization_model, :runtime_package_runtime_configuration_model,
                    :runtime_package_repository_metadata_model, :runtime_package_branch_resolution_model,
                    :runtime_package_credential_boundary_model, :runtime_package_observability_boundary_model,
                    :runtime_package_deployment_shape, :runtime_package_networking_boundary,
                    :runtime_package_upgrade_contract, :runtime_package_fail_fast_policy

        def initialize(decision:, next_action:, operator_action_required:, summary:, rerun_hint:, package_expectation:, runtime_package_guidance:, runtime_package_contract_health:, runtime_package_execution_modes:, runtime_package_execution_mode_contract:, runtime_package_schema_action:, runtime_package_preset_schema_action:, runtime_package_repo_source_action:, runtime_package_secret_delivery_action:, runtime_package_scheduler_store_migration_action:, runtime_package_recommended_execution_mode:, runtime_package_recommended_execution_mode_reason:, runtime_package_recommended_execution_mode_command:, runtime_package_operator_action:, runtime_package_operator_action_command:, runtime_package_next_execution_mode:, runtime_package_next_execution_mode_reason:, runtime_package_next_execution_mode_command:, runtime_package_next_command:, runtime_package_doctor_command:, runtime_package_runtime_validation_command:, runtime_package_startup_blockers:, runtime_package_migration_command:, runtime_package_runtime_command:, runtime_package_startup_sequence:, runtime_package_persistent_state_model:, runtime_package_retention_policy:, runtime_package_materialization_model:, runtime_package_runtime_configuration_model:, runtime_package_repository_metadata_model:, runtime_package_branch_resolution_model:, runtime_package_credential_boundary_model:, runtime_package_observability_boundary_model:, runtime_package_deployment_shape:, runtime_package_networking_boundary:, runtime_package_upgrade_contract:, runtime_package_fail_fast_policy:)
          @decision = decision.to_sym
          @next_action = next_action.to_sym
          @operator_action_required = operator_action_required
          @summary = summary
          @rerun_hint = rerun_hint
          @package_expectation = package_expectation.to_sym
          @runtime_package_guidance = runtime_package_guidance
          @runtime_package_contract_health = runtime_package_contract_health
          @runtime_package_execution_modes = runtime_package_execution_modes
          @runtime_package_execution_mode_contract = runtime_package_execution_mode_contract
          @runtime_package_schema_action = runtime_package_schema_action
          @runtime_package_preset_schema_action = runtime_package_preset_schema_action
          @runtime_package_repo_source_action = runtime_package_repo_source_action
          @runtime_package_secret_delivery_action = runtime_package_secret_delivery_action
          @runtime_package_scheduler_store_migration_action = runtime_package_scheduler_store_migration_action
          @runtime_package_recommended_execution_mode = runtime_package_recommended_execution_mode.to_sym
          @runtime_package_recommended_execution_mode_reason = runtime_package_recommended_execution_mode_reason
          @runtime_package_recommended_execution_mode_command = runtime_package_recommended_execution_mode_command
          @runtime_package_operator_action = runtime_package_operator_action.to_sym
          @runtime_package_operator_action_command = runtime_package_operator_action_command
          @runtime_package_next_execution_mode = runtime_package_next_execution_mode.to_sym
          @runtime_package_next_execution_mode_reason = runtime_package_next_execution_mode_reason
          @runtime_package_next_execution_mode_command = runtime_package_next_execution_mode_command
          @runtime_package_next_command = runtime_package_next_command
          @runtime_package_doctor_command = runtime_package_doctor_command
          @runtime_package_runtime_validation_command = runtime_package_runtime_validation_command
          @runtime_package_startup_blockers = runtime_package_startup_blockers
          @runtime_package_migration_command = runtime_package_migration_command
          @runtime_package_runtime_command = runtime_package_runtime_command
          @runtime_package_startup_sequence = runtime_package_startup_sequence
          @runtime_package_persistent_state_model = runtime_package_persistent_state_model
          @runtime_package_retention_policy = runtime_package_retention_policy
          @runtime_package_materialization_model = runtime_package_materialization_model
          @runtime_package_runtime_configuration_model = runtime_package_runtime_configuration_model
          @runtime_package_repository_metadata_model = runtime_package_repository_metadata_model
          @runtime_package_branch_resolution_model = runtime_package_branch_resolution_model
          @runtime_package_credential_boundary_model = runtime_package_credential_boundary_model
          @runtime_package_observability_boundary_model = runtime_package_observability_boundary_model
          @runtime_package_deployment_shape = runtime_package_deployment_shape
          @runtime_package_networking_boundary = runtime_package_networking_boundary
          @runtime_package_upgrade_contract = runtime_package_upgrade_contract
          @runtime_package_fail_fast_policy = runtime_package_fail_fast_policy
          freeze
        end

        def self.from_runtime_package(decision, doctor_result:)
          new(**RuntimePackageRecoveryAttributes.for_decision(decision: decision, doctor_result: doctor_result))
        end
      end
    end
  end
end
