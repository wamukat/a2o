# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Bootstrap do
  it "builds an immutable runtime environment config around the runtime package descriptor" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "project.yaml")
      preset_dir = File.join(dir, "presets")
      FileUtils.mkdir_p(preset_dir)
      File.write(
        manifest_path,
        YAML.dump(
          {
            "schema_version" => 1,
            "runtime" => {
              "phases" => {
                "implementation" => {
                  "skill" => "skills/implementation/base.md",
                  "workspace_hook" => "hooks/prepare-runtime.sh"
                },
                "review" => {
                  "skill" => "skills/review/default.md"
                },
                "verification" => {
                  "commands" => ["commands/verify-all"]
                },
                "remediation" => {
                  "commands" => ["commands/apply-remediation"]
                },
                "merge" => {
                  "target" => "merge_to_parent",
                  "policy" => "ff_only",
                  "target_ref" => "refs/heads/live"
                }
              }
            }
          }
        )
      )

      runtime_environment = described_class.runtime_environment_config(
        manifest_path: manifest_path,
        preset_dir: preset_dir,
        storage_backend: :json,
        storage_dir: dir,
        repo_sources: {},
        run_id_generator: -> { "run-1" }
      )

      expect(runtime_environment).to be_frozen
      expect(runtime_environment.runtime_package).to eq(
        described_class.runtime_package_descriptor(
          manifest_path: manifest_path,
          preset_dir: preset_dir,
          storage_backend: :json,
          storage_dir: dir,
          repo_sources: {}
        )
      )
      expect(runtime_environment.manifest_path.to_s).to eq(manifest_path)
      expect(runtime_environment.preset_dir.to_s).to eq(preset_dir)
      expect(runtime_environment.storage_backend).to eq(:json)
      expect(runtime_environment.storage_dir.to_s).to eq(dir)
      expect(runtime_environment.project_surface.implementation_skill).to eq("skills/implementation/base.md")
      expect(runtime_environment.project_context.merge_config.target).to eq(:merge_to_parent)
      expect(runtime_environment.container.fetch(:show_scheduler_state)).to be_a(A3::Application::ShowSchedulerState)
      expect(runtime_environment.operator_summary).to eq(
        {
          "mount" => "state_root=#{dir} logs_root=#{File.join(dir, 'logs')} workspace_root=#{File.join(dir, 'workspaces')} artifact_root=#{File.join(dir, 'artifacts')} migration_marker_path=#{File.join(dir, '.a3', 'scheduler-store-migration.applied')}",
          "writable_roots" => "#{dir},#{File.join(dir, 'workspaces')},#{File.join(dir, 'artifacts')}",
          "repo_sources" => "strategy=none slots= paths=",
          "distribution" => "image_ref=a3-engine:dev runtime_entrypoint=bin/a3 doctor_entrypoint=bin/a3 doctor-runtime",
          "schema_contract" => "project_config_schema_version=1 required_project_config_schema_version=1",
          "preset_schema_contract" => "required_preset_schema_version=1 preset_schema_versions=",
          "migration_command" => "bin/a3 migrate-scheduler-store #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}",
          "repo_source_contract" => "repo_source_strategy=none repo_source_slots=",
          "preset_schema_action" => "no preset schema action required",
          "secret_contract" => "secret_delivery_mode=environment_variable secret_reference=A3_SECRET",
          "migration_contract" => "scheduler_store_migration_state=not_required",
          "agent_runtime_profile" => "profile=host-local control_plane_url=http://127.0.0.1:7393 profile_path=<agent-runtime-profile.json> source_aliases= freshness_policy=reuse_if_clean_and_ref_matches cleanup_policy=retain_until_a3_cleanup",
          "agent_runtime_command" => "a3-agent -config <agent-runtime-profile.json>",
          "agent_worker_gateway_options" => "--worker-gateway agent-http --agent-control-plane-url http://127.0.0.1:7393 --agent-runtime-profile host-local --agent-shared-workspace-mode agent-materialized --agent-workspace-freshness-policy reuse_if_clean_and_ref_matches --agent-workspace-cleanup-policy retain_until_a3_cleanup",
          "persistent_state_model" => "scheduler_state_root=#{File.join(dir, 'scheduler')} task_repository_root=#{File.join(dir, 'tasks')} run_repository_root=#{File.join(dir, 'runs')} evidence_root=#{File.join(dir, 'evidence')} blocked_diagnosis_root=#{File.join(dir, 'blocked_diagnoses')} artifact_owner_cache_root=#{File.join(dir, 'artifact_owner_cache')} logs_root=#{File.join(dir, 'logs')} workspace_root=#{File.join(dir, 'workspaces')} artifact_root=#{File.join(dir, 'artifacts')}",
          "retention_policy" => "terminal_workspace_cleanup=retention_policy_controlled blocked_evidence_retention=independent_from_scheduler_cleanup image_upgrade_cleanup_trigger=none",
          "materialization_model" => "repo_slot_namespace=task_workspace_fixed implementation_workspace=ticket_workspace review_workspace=runtime_workspace verification_workspace=runtime_workspace merge_workspace=runtime_workspace missing_repo_rescue=forbidden source_descriptor_alignment=required_before_phase_start",
          "runtime_configuration_model" => "project_config_path=required preset_dir=required storage_backend=required state_root=required workspace_root=required artifact_root=required repo_source_strategy=required repository_metadata=required authoritative_branch_resolution=required integration_target_resolution=required secret_reference=required",
          "repository_metadata_model" => "repository_metadata=runtime_package_scoped source_descriptor_ref_resolution=required review_target_resolution=evidence_driven",
          "branch_resolution_model" => "authoritative_branch_resolution=runtime_package_scoped integration_target_resolution=runtime_package_scoped branch_integration_inputs=required",
          "credential_boundary_model" => "secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only",
          "deployment_shape" => "runtime_package=single_project writable_state=isolated scheduler_instance=single_project state_boundary=project secret_boundary=project",
          "networking_boundary" => "outbound=git,issue_api,package_registry,llm_gateway,verification_service secret_source=secret_store token_scope=project",
          "observability_boundary_model" => "operator_logs_root=#{File.join(dir, 'logs')} blocked_diagnosis_root=#{File.join(dir, 'blocked_diagnoses')} evidence_root=#{File.join(dir, 'evidence')} validation_output=stdout_only workspace_debug_reference=path_only",
          "upgrade_contract" => "image_upgrade=independent project_config_schema_version=1 preset_schema_version=1 state_migration=explicit",
          "fail_fast_policy" => "project_config_schema_mismatch=fail_fast preset_schema_conflict=fail_fast writable_mount_missing=fail_fast secret_missing=fail_fast scheduler_store_migration_pending=fail_fast",
          "runtime_contract" => "project_config_schema_version=1 required_project_config_schema_version=1 required_preset_schema_version=1 preset_schema_versions= repo_source_strategy=none repo_source_slots= secret_delivery_mode=environment_variable secret_reference=A3_SECRET scheduler_store_migration_state=not_required",
          "schema_action" => "update project.yaml schema to 1",
          "repo_source_action" => "no repo source action required",
          "secret_delivery_action" => "provide secrets via environment variable A3_SECRET",
          "scheduler_store_migration_action" => "scheduler store migration not required",
          "startup_checklist" => "provide secrets via environment variable A3_SECRET; scheduler store migration not required",
          "execution_mode_contract" => "one_shot_cli=operator_driven_doctor_migration_runtime ; scheduler_loop=continuous_runnable_processing_after_runtime_ready ; doctor_inspect=configuration_and_mount_validation_only",
          "execution_modes" => "one_shot_cli=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} | bin/a3 migrate-scheduler-store #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} | bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} ; scheduler_loop=bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} ; doctor_inspect=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}",
          "descriptor_startup_readiness" => "descriptor_ready",
          "doctor_command" => "bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}",
          "runtime_validation_command" => "bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} && bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}",
          "startup_sequence" => "doctor=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} migrate=skip runtime=bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}",
          "runtime_command" => "bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}",
          "operator_action" => "provide secrets via environment variable A3_SECRET; scheduler store migration not required"
        }.freeze
      )
      expect(runtime_environment.validate!).to be(runtime_environment)
      expect(runtime_environment.healthy?).to be(true)
    end
  end

  it "builds a runtime-only doctor config without project bootstrap dependencies" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "project.yaml")
      preset_dir = File.join(dir, "presets")
      FileUtils.mkdir_p(preset_dir)
      File.write(manifest_path, "schema_version: 1\nruntime:\n  presets: []\n")

      runtime_environment = described_class.doctor_runtime_environment_config(
        manifest_path: manifest_path,
        preset_dir: preset_dir,
        storage_backend: :json,
        storage_dir: dir,
        repo_sources: {}
      )

      expect(runtime_environment).to be_frozen
      expect(runtime_environment.runtime_package).to eq(
        described_class.runtime_package_descriptor(
          manifest_path: manifest_path,
          preset_dir: preset_dir,
          storage_backend: :json,
          storage_dir: dir,
          repo_sources: {}
        )
      )
      expect(runtime_environment.project_surface).to be_nil
      expect(runtime_environment.project_context).to be_nil
      expect(runtime_environment.container).to be_nil
      expect(runtime_environment.operator_summary).to eq(
        {
          "mount" => "state_root=#{dir} logs_root=#{File.join(dir, 'logs')} workspace_root=#{File.join(dir, 'workspaces')} artifact_root=#{File.join(dir, 'artifacts')} migration_marker_path=#{File.join(dir, '.a3', 'scheduler-store-migration.applied')}",
          "writable_roots" => "#{dir},#{File.join(dir, 'workspaces')},#{File.join(dir, 'artifacts')}",
          "repo_sources" => "strategy=none slots= paths=",
          "distribution" => "image_ref=a3-engine:dev runtime_entrypoint=bin/a3 doctor_entrypoint=bin/a3 doctor-runtime",
          "schema_contract" => "project_config_schema_version=1 required_project_config_schema_version=1",
          "preset_schema_contract" => "required_preset_schema_version=1 preset_schema_versions=",
          "migration_command" => "bin/a3 migrate-scheduler-store #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}",
          "repo_source_contract" => "repo_source_strategy=none repo_source_slots=",
          "preset_schema_action" => "no preset schema action required",
          "secret_contract" => "secret_delivery_mode=environment_variable secret_reference=A3_SECRET",
          "migration_contract" => "scheduler_store_migration_state=not_required",
          "agent_runtime_profile" => "profile=host-local control_plane_url=http://127.0.0.1:7393 profile_path=<agent-runtime-profile.json> source_aliases= freshness_policy=reuse_if_clean_and_ref_matches cleanup_policy=retain_until_a3_cleanup",
          "agent_runtime_command" => "a3-agent -config <agent-runtime-profile.json>",
          "agent_worker_gateway_options" => "--worker-gateway agent-http --agent-control-plane-url http://127.0.0.1:7393 --agent-runtime-profile host-local --agent-shared-workspace-mode agent-materialized --agent-workspace-freshness-policy reuse_if_clean_and_ref_matches --agent-workspace-cleanup-policy retain_until_a3_cleanup",
          "persistent_state_model" => "scheduler_state_root=#{File.join(dir, 'scheduler')} task_repository_root=#{File.join(dir, 'tasks')} run_repository_root=#{File.join(dir, 'runs')} evidence_root=#{File.join(dir, 'evidence')} blocked_diagnosis_root=#{File.join(dir, 'blocked_diagnoses')} artifact_owner_cache_root=#{File.join(dir, 'artifact_owner_cache')} logs_root=#{File.join(dir, 'logs')} workspace_root=#{File.join(dir, 'workspaces')} artifact_root=#{File.join(dir, 'artifacts')}",
          "retention_policy" => "terminal_workspace_cleanup=retention_policy_controlled blocked_evidence_retention=independent_from_scheduler_cleanup image_upgrade_cleanup_trigger=none",
          "materialization_model" => "repo_slot_namespace=task_workspace_fixed implementation_workspace=ticket_workspace review_workspace=runtime_workspace verification_workspace=runtime_workspace merge_workspace=runtime_workspace missing_repo_rescue=forbidden source_descriptor_alignment=required_before_phase_start",
          "runtime_configuration_model" => "project_config_path=required preset_dir=required storage_backend=required state_root=required workspace_root=required artifact_root=required repo_source_strategy=required repository_metadata=required authoritative_branch_resolution=required integration_target_resolution=required secret_reference=required",
          "repository_metadata_model" => "repository_metadata=runtime_package_scoped source_descriptor_ref_resolution=required review_target_resolution=evidence_driven",
          "branch_resolution_model" => "authoritative_branch_resolution=runtime_package_scoped integration_target_resolution=runtime_package_scoped branch_integration_inputs=required",
          "credential_boundary_model" => "secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only",
          "deployment_shape" => "runtime_package=single_project writable_state=isolated scheduler_instance=single_project state_boundary=project secret_boundary=project",
          "networking_boundary" => "outbound=git,issue_api,package_registry,llm_gateway,verification_service secret_source=secret_store token_scope=project",
          "observability_boundary_model" => "operator_logs_root=#{File.join(dir, 'logs')} blocked_diagnosis_root=#{File.join(dir, 'blocked_diagnoses')} evidence_root=#{File.join(dir, 'evidence')} validation_output=stdout_only workspace_debug_reference=path_only",
          "upgrade_contract" => "image_upgrade=independent project_config_schema_version=1 preset_schema_version=1 state_migration=explicit",
          "fail_fast_policy" => "project_config_schema_mismatch=fail_fast preset_schema_conflict=fail_fast writable_mount_missing=fail_fast secret_missing=fail_fast scheduler_store_migration_pending=fail_fast",
          "runtime_contract" => "project_config_schema_version=1 required_project_config_schema_version=1 required_preset_schema_version=1 preset_schema_versions= repo_source_strategy=none repo_source_slots= secret_delivery_mode=environment_variable secret_reference=A3_SECRET scheduler_store_migration_state=not_required",
          "schema_action" => "update project.yaml schema to 1",
          "repo_source_action" => "no repo source action required",
          "secret_delivery_action" => "provide secrets via environment variable A3_SECRET",
          "scheduler_store_migration_action" => "scheduler store migration not required",
          "startup_checklist" => "provide secrets via environment variable A3_SECRET; scheduler store migration not required",
          "execution_mode_contract" => "one_shot_cli=operator_driven_doctor_migration_runtime ; scheduler_loop=continuous_runnable_processing_after_runtime_ready ; doctor_inspect=configuration_and_mount_validation_only",
          "execution_modes" => "one_shot_cli=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} | bin/a3 migrate-scheduler-store #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} | bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} ; scheduler_loop=bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} ; doctor_inspect=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}",
          "descriptor_startup_readiness" => "descriptor_ready",
          "doctor_command" => "bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}",
          "runtime_validation_command" => "bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} && bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}",
          "startup_sequence" => "doctor=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} migrate=skip runtime=bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}",
          "runtime_command" => "bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}",
          "operator_action" => "provide secrets via environment variable A3_SECRET; scheduler store migration not required"
        }.freeze
      )
    end
  end
end
