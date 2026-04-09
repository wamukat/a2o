# frozen_string_literal: true

module A3
  module CLI
    module RuntimeOutputFormatter
      module_function

      def doctor_lines(result:, runtime_package:)
        lines = []
        lines << "runtime_doctor=#{result.status}"
        lines << "project_runtime_root=#{result.project_runtime_root}"
        lines << "runtime_summary.writable_roots=#{runtime_package.writable_roots.join(',')}"
        lines.concat(runtime_summary_lines(
                       operator_summary: runtime_package.operator_summary,
                       mount_summary: result.mount_summary,
                       repo_source_summary: result.repo_source_summary,
                       distribution_summary: result.distribution_summary,
                       startup_readiness: result.startup_readiness,
                       recommended_execution_mode: result.recommended_execution_mode,
                       recommended_execution_mode_reason: result.recommended_execution_mode_reason,
                       recommended_execution_mode_command: result.recommended_execution_mode_command,
                       startup_blockers: result.startup_blockers,
                       runtime_canary_command: result.runtime_canary_command_summary,
                       next_command: result.next_command,
                       startup_sequence: result.startup_sequence,
                       contract_health: result.contract_health,
                       operator_guidance: result.operator_guidance
                     ))
        lines.concat(distribution_lines(result.distribution_summary))
        lines << "image_version=#{result.image_version}"
        lines << "storage_backend=#{result.storage_backend}"
        lines << "writable_roots=#{result.writable_roots.join(',')}"
        lines.concat(mount_detail_lines(result.mount_summary))
        lines.concat(repo_source_detail_lines(
                       strategy: result.repo_source_strategy,
                       slots: result.repo_source_slots,
                       paths: result.repo_source_paths,
                       summary: result.repo_source_summary
                     ))
        lines.concat(check_lines(result.checks))
        lines
      end

      def package_lines(descriptor:)
        lines = []
        lines << "image_version=#{descriptor.image_version}"
        lines << "manifest_path=#{descriptor.manifest_path}"
        lines << "project_runtime_root=#{descriptor.project_runtime_root}"
        lines.concat(descriptor_runtime_summary_lines(descriptor))
        lines.concat(distribution_lines(descriptor.distribution_summary))
        lines << "preset_dir=#{descriptor.preset_dir}"
        lines << "storage_backend=#{descriptor.storage_backend}"
        lines << "state_root=#{descriptor.state_root}"
        lines << "workspace_root=#{descriptor.workspace_root}"
        lines << "artifact_root=#{descriptor.artifact_root}"
        lines << "writable_roots=#{descriptor.writable_roots.join(',')}"
        lines.concat(repo_source_detail_lines(
                       strategy: descriptor.repo_source_strategy,
                       slots: descriptor.repo_source_slots,
                       paths: descriptor.repo_source_summary.fetch("sources"),
                       summary: descriptor.repo_source_summary
                     ))
        lines
      end

      def canary_lines(result:, runtime_package:)
        lines = []
        lines << "runtime_canary=#{result.status}"
        lines << "image_version=#{runtime_package.image_version}"
        lines << "project_runtime_root=#{runtime_package.project_runtime_root}"
        lines << "storage_backend=#{runtime_package.storage_backend}"
        lines << "writable_roots=#{runtime_package.writable_roots.join(',')}"
        lines.concat(runtime_summary_lines(
                       operator_summary: runtime_package.operator_summary,
                       mount_summary: result.doctor_result.mount_summary,
                       repo_source_summary: result.doctor_result.repo_source_summary,
                       distribution_summary: result.doctor_result.distribution_summary,
                       startup_readiness: result.doctor_result.startup_readiness,
                       recommended_execution_mode: result.doctor_result.recommended_execution_mode,
                       recommended_execution_mode_reason: result.doctor_result.recommended_execution_mode_reason,
                       recommended_execution_mode_command: result.doctor_result.recommended_execution_mode_command,
                       startup_blockers: result.doctor_result.startup_blockers,
                       runtime_canary_command: result.doctor_result.runtime_canary_command_summary,
                       next_command: result.doctor_result.next_command,
                       startup_sequence: result.doctor_result.startup_sequence,
                       contract_health: result.doctor_result.contract_health,
                       operator_guidance: result.doctor_result.operator_guidance
                     ))
        lines.concat(distribution_lines(result.doctor_result.distribution_summary))
        lines.concat(mount_detail_lines(result.doctor_result.mount_summary))
        lines.concat(repo_source_detail_lines(
                       strategy: result.doctor_result.repo_source_strategy,
                       slots: result.doctor_result.repo_source_slots,
                       paths: result.doctor_result.repo_source_paths,
                       summary: result.doctor_result.repo_source_summary
                     ))
        lines << "operator_action=#{result.operator_action}"
        lines << "operator_action_command=#{result.operator_action_command}"
        lines << "next_execution_mode=#{result.next_execution_mode}"
        lines << "next_execution_mode_reason=#{result.next_execution_mode_reason}"
        lines << "next_execution_mode_command=#{result.next_execution_mode_command}"
        lines.concat(check_lines(result.doctor_result.checks))
        if result.migration_result
          lines << "migration_status=#{result.migration_result.status}"
          lines << "migration_marker_path=#{result.migration_result.marker_path}"
        end
        if result.scheduler_result
          lines << "executed=#{result.scheduler_result.executed_count}"
          lines << "idle=#{result.scheduler_result.idle_reached}"
          lines << "stop_reason=#{result.scheduler_result.stop_reason}"
          lines << "quarantined=#{result.scheduler_result.quarantined_count}"
        end
        lines
      end

      def descriptor_runtime_summary_lines(descriptor)
        lines = []
        lines << "runtime_summary.mount=#{mount_summary_line(descriptor.mount_summary)}"
        lines << "runtime_summary.writable_roots=#{descriptor.writable_roots.join(',')}"
        lines << "runtime_summary.repo_sources=#{repo_sources_line(descriptor.repo_source_summary)}"
        lines << "runtime_summary.distribution=#{descriptor.operator_summary.fetch('distribution')}"
        lines << "runtime_summary.persistent_state_model=#{descriptor.operator_summary.fetch('persistent_state_model')}"
        lines << "runtime_summary.retention_policy=#{descriptor.operator_summary.fetch('retention_policy')}"
        lines << "runtime_summary.materialization_model=#{descriptor.operator_summary.fetch('materialization_model')}"
        lines << "runtime_summary.runtime_configuration_model=#{descriptor.operator_summary.fetch('runtime_configuration_model')}"
        lines << "runtime_summary.repository_metadata_model=#{descriptor.operator_summary.fetch('repository_metadata_model')}"
        lines << "runtime_summary.branch_resolution_model=#{descriptor.operator_summary.fetch('branch_resolution_model')}"
        lines << "runtime_summary.credential_boundary_model=#{descriptor.operator_summary.fetch('credential_boundary_model')}"
        lines << "runtime_summary.observability_boundary_model=#{descriptor.operator_summary.fetch('observability_boundary_model')}"
        lines << "runtime_summary.deployment_shape=#{descriptor.operator_summary.fetch('deployment_shape')}"
        lines << "runtime_summary.networking_boundary=#{descriptor.operator_summary.fetch('networking_boundary')}"
        lines << "runtime_summary.upgrade_contract=#{descriptor.operator_summary.fetch('upgrade_contract')}"
        lines << "runtime_summary.fail_fast_policy=#{descriptor.operator_summary.fetch('fail_fast_policy')}"
        lines << "runtime_summary.schema_contract=#{descriptor.operator_summary.fetch('schema_contract')}"
        lines << "runtime_summary.preset_schema_contract=#{descriptor.operator_summary.fetch('preset_schema_contract')}"
        lines << "runtime_summary.repo_source_contract=#{descriptor.operator_summary.fetch('repo_source_contract')}"
        lines << "runtime_summary.secret_contract=#{descriptor.operator_summary.fetch('secret_contract')}"
        lines << "runtime_summary.migration_contract=#{descriptor.operator_summary.fetch('migration_contract')}"
        lines << "runtime_summary.runtime_contract=#{descriptor.operator_summary.fetch('runtime_contract')}"
        lines << "runtime_summary.repo_source_action=#{descriptor.operator_summary.fetch('repo_source_action')}"
        lines << "runtime_summary.preset_schema_action=#{descriptor.operator_summary.fetch('preset_schema_action')}"
        lines << "runtime_summary.secret_delivery_action=#{descriptor.operator_summary.fetch('secret_delivery_action')}"
        lines << "runtime_summary.scheduler_store_migration_action=#{descriptor.operator_summary.fetch('scheduler_store_migration_action')}"
        lines << "runtime_summary.startup_checklist=#{descriptor.operator_summary.fetch('startup_checklist')}"
        lines << "runtime_summary.execution_modes=#{descriptor.operator_summary.fetch('execution_modes')}"
        lines << "runtime_summary.execution_mode_contract=#{descriptor.operator_summary.fetch('execution_mode_contract')}"
        lines << "runtime_summary.descriptor_startup_readiness=#{descriptor.operator_summary.fetch('descriptor_startup_readiness')}"
        lines << "runtime_summary.doctor_command=#{descriptor.operator_summary.fetch('doctor_command')}"
        lines << "runtime_summary.migration_command=#{descriptor.operator_summary.fetch('migration_command')}"
        lines << "runtime_summary.runtime_command=#{descriptor.operator_summary.fetch('runtime_command')}"
        lines << "runtime_summary.runtime_canary_command=#{descriptor.operator_summary.fetch('runtime_canary_command')}"
        lines << "runtime_summary.startup_sequence=#{descriptor.operator_summary.fetch('startup_sequence')}"
        lines << "runtime_summary.operator_action=#{descriptor.operator_summary.fetch('operator_action')}"
        lines
      end

      def runtime_summary_lines(operator_summary:, mount_summary:, repo_source_summary:, distribution_summary:, startup_readiness:, recommended_execution_mode:, recommended_execution_mode_reason:, recommended_execution_mode_command:, startup_blockers:, runtime_canary_command:, next_command:, startup_sequence:, contract_health:, operator_guidance:)
        lines = []
        lines << "runtime_summary.contract_health=#{contract_health}"
        lines << "runtime_summary.mount=#{mount_summary_line(mount_summary)}"
        lines << "runtime_summary.repo_sources=#{repo_sources_line(repo_source_summary)}"
        lines << "runtime_summary.distribution=image_ref=#{distribution_summary.fetch('image_ref')} runtime_entrypoint=#{distribution_summary.fetch('runtime_entrypoint')} doctor_entrypoint=#{distribution_summary.fetch('doctor_entrypoint')}"
        lines << "runtime_summary.execution_modes=#{operator_summary.fetch('execution_modes')}"
        lines << "runtime_summary.execution_mode_contract=#{operator_summary.fetch('execution_mode_contract')}"
        lines << "runtime_summary.persistent_state_model=#{distribution_summary.fetch('persistent_state_model')}"
        lines << "runtime_summary.retention_policy=#{distribution_summary.fetch('retention_policy')}"
        lines << "runtime_summary.materialization_model=#{distribution_summary.fetch('materialization_model')}"
        lines << "runtime_summary.runtime_configuration_model=#{distribution_summary.fetch('runtime_configuration_model')}"
        lines << "runtime_summary.repository_metadata_model=#{distribution_summary.fetch('repository_metadata_model')}"
        lines << "runtime_summary.branch_resolution_model=#{distribution_summary.fetch('branch_resolution_model')}"
        lines << "runtime_summary.credential_boundary_model=#{distribution_summary.fetch('credential_boundary_model')}"
        lines << "runtime_summary.observability_boundary_model=#{distribution_summary.fetch('observability_boundary_model')}"
        lines << "runtime_summary.deployment_shape=#{distribution_summary.fetch('deployment_shape')}"
        lines << "runtime_summary.networking_boundary=#{distribution_summary.fetch('networking_boundary')}"
        lines << "runtime_summary.upgrade_contract=#{distribution_summary.fetch('upgrade_contract')}"
        lines << "runtime_summary.fail_fast_policy=#{distribution_summary.fetch('fail_fast_policy')}"
        lines << "runtime_summary.schema_contract=#{operator_summary.fetch('schema_contract')}"
        lines << "runtime_summary.preset_schema_contract=#{operator_summary.fetch('preset_schema_contract')}"
        lines << "runtime_summary.repo_source_contract=#{operator_summary.fetch('repo_source_contract')}"
        lines << "runtime_summary.secret_contract=#{operator_summary.fetch('secret_contract')}"
        lines << "runtime_summary.migration_contract=#{operator_summary.fetch('migration_contract')}"
        lines << "runtime_summary.runtime_contract=#{operator_summary.fetch('runtime_contract')}"
        lines << "runtime_summary.repo_source_action=#{operator_summary.fetch('repo_source_action')}"
        lines << "runtime_summary.preset_schema_action=#{operator_summary.fetch('preset_schema_action')}"
        lines << "runtime_summary.secret_delivery_action=#{operator_summary.fetch('secret_delivery_action')}"
        lines << "runtime_summary.scheduler_store_migration_action=#{operator_summary.fetch('scheduler_store_migration_action')}"
        lines << "runtime_summary.startup_checklist=#{operator_summary.fetch('startup_checklist')}"
        lines << "runtime_summary.recommended_execution_mode=#{recommended_execution_mode}"
        lines << "runtime_summary.recommended_execution_mode_reason=#{recommended_execution_mode_reason}"
        lines << "runtime_summary.recommended_execution_mode_command=#{recommended_execution_mode_command}"
        lines << "runtime_summary.startup_readiness=#{startup_readiness}"
        lines << "runtime_summary.startup_blockers=#{startup_blockers}"
        lines << "runtime_summary.operator_guidance=#{operator_guidance}"
        lines << "runtime_summary.next_command=#{next_command}"
        lines << "runtime_summary.doctor_command=#{operator_summary.fetch('doctor_command')}"
        lines << "runtime_summary.migration_command=#{operator_summary.fetch('migration_command')}"
        lines << "runtime_summary.runtime_command=#{operator_summary.fetch('runtime_command')}"
        lines << "runtime_summary.runtime_canary_command=#{runtime_canary_command}"
        lines << "runtime_summary.startup_sequence=#{startup_sequence}"
        lines << "runtime_summary.operator_action=#{operator_summary.fetch('operator_action')}"
        lines
      end

      def distribution_lines(distribution_summary)
        [
          "distribution_summary.image_ref=#{distribution_summary.fetch('image_ref')}",
          "distribution_summary.runtime_entrypoint=#{distribution_summary.fetch('runtime_entrypoint')}",
          "distribution_summary.doctor_entrypoint=#{distribution_summary.fetch('doctor_entrypoint')}",
          "distribution_summary.migration_entrypoint=#{distribution_summary.fetch('migration_entrypoint')}",
          "distribution_summary.manifest_schema_version=#{distribution_summary.fetch('manifest_schema_version')}",
          "distribution_summary.required_manifest_schema_version=#{distribution_summary.fetch('required_manifest_schema_version')}",
          "distribution_summary.schema_contract=#{distribution_summary.fetch('schema_contract')}",
          "distribution_summary.preset_chain=#{distribution_summary.fetch('preset_chain').join(',')}",
          "distribution_summary.preset_schema_versions=#{distribution_summary.fetch('preset_schema_versions').map { |preset, version| "#{preset}=#{version}" }.join(',')}",
          "distribution_summary.required_preset_schema_version=#{distribution_summary.fetch('required_preset_schema_version')}",
          "distribution_summary.preset_schema_contract=#{distribution_summary.fetch('preset_schema_contract')}",
          "distribution_summary.secret_delivery_mode=#{distribution_summary.fetch('secret_delivery_mode')}",
          "distribution_summary.secret_reference=#{distribution_summary.fetch('secret_reference')}",
          "distribution_summary.secret_contract=#{distribution_summary.fetch('secret_contract')}",
          "distribution_summary.scheduler_store_migration_state=#{distribution_summary.fetch('scheduler_store_migration_state')}",
          "distribution_summary.migration_contract=#{distribution_summary.fetch('migration_contract')}",
          "distribution_summary.persistent_state_model=#{distribution_summary.fetch('persistent_state_model')}",
          "distribution_summary.retention_policy=#{distribution_summary.fetch('retention_policy')}",
          "distribution_summary.materialization_model=#{distribution_summary.fetch('materialization_model')}",
          "distribution_summary.runtime_configuration_model=#{distribution_summary.fetch('runtime_configuration_model')}",
          "distribution_summary.repository_metadata_model=#{distribution_summary.fetch('repository_metadata_model')}",
          "distribution_summary.branch_resolution_model=#{distribution_summary.fetch('branch_resolution_model')}",
          "distribution_summary.credential_boundary_model=#{distribution_summary.fetch('credential_boundary_model')}",
          "distribution_summary.observability_boundary_model=#{distribution_summary.fetch('observability_boundary_model')}",
          "distribution_summary.deployment_shape=#{distribution_summary.fetch('deployment_shape')}",
          "distribution_summary.networking_boundary=#{distribution_summary.fetch('networking_boundary')}",
          "distribution_summary.upgrade_contract=#{distribution_summary.fetch('upgrade_contract')}",
          "distribution_summary.fail_fast_policy=#{distribution_summary.fetch('fail_fast_policy')}"
        ]
      end

      def mount_detail_lines(mount_summary)
        [
          "mount_summary.state_root=#{mount_summary.fetch('state_root')}",
          "mount_summary.logs_root=#{mount_summary.fetch('logs_root')}",
          "mount_summary.workspace_root=#{mount_summary.fetch('workspace_root')}",
          "mount_summary.artifact_root=#{mount_summary.fetch('artifact_root')}",
          "mount_summary.migration_marker_path=#{mount_summary.fetch('migration_marker_path')}"
        ]
      end

      def repo_source_detail_lines(strategy:, slots:, paths:, summary:)
        normalized_paths = paths.map { |slot, path| "#{slot}=#{path}" }.join(',')
        [
          "repo_source_strategy=#{strategy}",
          "repo_source_slots=#{slots.join(',')}",
          "repo_source_paths=#{normalized_paths}",
          "repo_source_details=#{summary.fetch('strategy')}:#{summary.fetch('slots').join(',')}"
        ]
      end

      def check_lines(checks)
        checks.map { |check| "check.#{check.name}=#{check.status} path=#{check.path} detail=#{check.detail}" }
      end

      def mount_summary_line(mount_summary)
        "state_root=#{mount_summary.fetch('state_root')} logs_root=#{mount_summary.fetch('logs_root')} workspace_root=#{mount_summary.fetch('workspace_root')} artifact_root=#{mount_summary.fetch('artifact_root')} migration_marker_path=#{mount_summary.fetch('migration_marker_path')}"
      end

      def repo_sources_line(repo_source_summary)
        "strategy=#{repo_source_summary.fetch('strategy')} slots=#{repo_source_summary.fetch('slots').join(',')} paths=#{repo_source_summary.fetch('sources').map { |slot, path| "#{slot}=#{path}" }.join(',')}"
      end
    end
  end
end
