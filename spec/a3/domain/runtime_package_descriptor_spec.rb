# frozen_string_literal: true

RSpec.describe A3::Domain::RuntimePackageDescriptor do
  it "derives a distribution contract from the image version by default" do
    descriptor = described_class.build(
      image_version: "a3:v2.1.0",
      manifest_path: "/tmp/runtime/project.yaml",
      preset_dir: "/tmp/runtime/presets",
      storage_backend: :sqlite,
      storage_dir: "/tmp/runtime/state",
      repo_sources: {},
      manifest_schema_version: "1",
      required_manifest_schema_version: "1",
      preset_chain: [],
      preset_schema_versions: {},
      required_preset_schema_version: "1",
        secret_reference: "A3_SECRET"
    )

    expect(descriptor.distribution_image_ref).to eq("a3-engine:a3:v2.1.0")
    expect(descriptor.runtime_entrypoint).to eq("bin/a3")
    expect(descriptor.doctor_entrypoint).to eq("bin/a3 doctor-runtime")
    expect(descriptor.migration_entrypoint).to eq("bin/a3 migrate-scheduler-store")
    expect(descriptor.migration_marker_path).to eq(Pathname("/tmp/runtime/state/.a3/scheduler-store-migration.applied"))
    expect(descriptor.mount_summary).to eq(
      "state_root" => Pathname("/tmp/runtime/state"),
      "logs_root" => Pathname("/tmp/runtime/state/logs"),
      "workspace_root" => Pathname("/tmp/runtime/state/workspaces"),
      "artifact_root" => Pathname("/tmp/runtime/state/artifacts"),
      "migration_marker_path" => Pathname("/tmp/runtime/state/.a3/scheduler-store-migration.applied")
    )
    expect(descriptor.distribution_summary).to eq(
      "image_ref" => "a3-engine:a3:v2.1.0",
      "runtime_entrypoint" => "bin/a3",
      "doctor_entrypoint" => "bin/a3 doctor-runtime",
      "migration_entrypoint" => "bin/a3 migrate-scheduler-store",
      "project_config_schema_version" => "1",
      "required_project_config_schema_version" => "1",
      "preset_chain" => [],
      "preset_schema_versions" => {},
      "required_preset_schema_version" => "1",
      "migration_marker_path" => Pathname("/tmp/runtime/state/.a3/scheduler-store-migration.applied"),
      "schema_contract" => "project_config_schema_version=1 required_project_config_schema_version=1",
      "preset_schema_contract" => "required_preset_schema_version=1 preset_schema_versions=",
      "secret_delivery_mode" => :environment_variable,
      "secret_reference" => "A3_SECRET",
      "secret_contract" => "secret_delivery_mode=environment_variable secret_reference=A3_SECRET",
      "scheduler_store_migration_state" => :not_required,
      "migration_contract" => "scheduler_store_migration_state=not_required",
      "persistent_state_model" => "scheduler_state_root=/tmp/runtime/state/scheduler task_repository_root=/tmp/runtime/state/tasks run_repository_root=/tmp/runtime/state/runs evidence_root=/tmp/runtime/state/evidence blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses artifact_owner_cache_root=/tmp/runtime/state/artifact_owner_cache logs_root=/tmp/runtime/state/logs workspace_root=/tmp/runtime/state/workspaces artifact_root=/tmp/runtime/state/artifacts",
      "retention_policy" => "terminal_workspace_cleanup=retention_policy_controlled blocked_evidence_retention=independent_from_scheduler_cleanup image_upgrade_cleanup_trigger=none",
      "materialization_model" => "repo_slot_namespace=task_workspace_fixed implementation_workspace=ticket_workspace review_workspace=runtime_workspace verification_workspace=runtime_workspace merge_workspace=runtime_workspace missing_repo_rescue=forbidden source_descriptor_alignment=required_before_phase_start",
      "runtime_configuration_model" => "project_config_path=required preset_dir=required storage_backend=required state_root=required workspace_root=required artifact_root=required repo_source_strategy=required repository_metadata=required authoritative_branch_resolution=required integration_target_resolution=required secret_reference=required",
      "repository_metadata_model" => "repository_metadata=runtime_package_scoped source_descriptor_ref_resolution=required review_target_resolution=evidence_driven",
      "branch_resolution_model" => "authoritative_branch_resolution=runtime_package_scoped integration_target_resolution=runtime_package_scoped branch_integration_inputs=required",
      "credential_boundary_model" => "secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only",
      "observability_boundary_model" => "operator_logs_root=/tmp/runtime/state/logs blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses evidence_root=/tmp/runtime/state/evidence validation_output=stdout_only workspace_debug_reference=path_only",
      "deployment_shape" => "runtime_package=single_project writable_state=isolated scheduler_instance=single_project state_boundary=project secret_boundary=project",
      "networking_boundary" => "outbound=git,issue_api,package_registry,llm_gateway,verification_service secret_source=secret_store token_scope=project",
      "upgrade_contract" => "image_upgrade=independent project_config_schema_version=1 preset_schema_version=1 state_migration=explicit",
      "fail_fast_policy" => "project_config_schema_mismatch=fail_fast preset_schema_conflict=fail_fast writable_mount_missing=fail_fast secret_missing=fail_fast scheduler_store_migration_pending=fail_fast"
    )
    expect(descriptor.operator_summary.fetch("repo_source_contract")).to eq("repo_source_strategy=none repo_source_slots=")
    expect(descriptor.operator_summary.fetch("repo_source_action")).to eq("no repo source action required")
    expect(descriptor.operator_summary.fetch("schema_contract")).to eq("project_config_schema_version=1 required_project_config_schema_version=1")
    expect(descriptor.operator_summary.fetch("preset_schema_contract")).to eq("required_preset_schema_version=1 preset_schema_versions=")
    expect(descriptor.operator_summary.fetch("schema_action")).to eq("update project.yaml schema to 1")
    expect(descriptor.operator_summary.fetch("preset_schema_action")).to eq("no preset schema action required")
    expect(descriptor.operator_summary.fetch("secret_contract")).to eq("secret_delivery_mode=environment_variable secret_reference=A3_SECRET")
    expect(descriptor.operator_summary.fetch("migration_contract")).to eq("scheduler_store_migration_state=not_required")
    expect(descriptor.operator_summary.fetch("agent_runtime_profile")).to eq("profile=host-local control_plane_url=http://127.0.0.1:7393 profile_path=<agent-runtime-profile.json> source_aliases= freshness_policy=reuse_if_clean_and_ref_matches cleanup_policy=retain_until_a3_cleanup")
    expect(descriptor.operator_summary.fetch("agent_runtime_command")).to eq("a3-agent -config <agent-runtime-profile.json>")
    expect(descriptor.operator_summary.fetch("agent_worker_gateway_options")).to eq("--worker-gateway agent-http --agent-control-plane-url http://127.0.0.1:7393 --agent-runtime-profile host-local --agent-shared-workspace-mode agent-materialized --agent-workspace-freshness-policy reuse_if_clean_and_ref_matches --agent-workspace-cleanup-policy retain_until_a3_cleanup")
    expect(descriptor.operator_summary.fetch("runtime_contract")).to eq("project_config_schema_version=1 required_project_config_schema_version=1 required_preset_schema_version=1 preset_schema_versions= repo_source_strategy=none repo_source_slots= secret_delivery_mode=environment_variable secret_reference=A3_SECRET scheduler_store_migration_state=not_required")
    expect(descriptor.operator_summary.fetch("secret_delivery_action")).to eq("provide secrets via environment variable A3_SECRET")
    expect(descriptor.operator_summary.fetch("scheduler_store_migration_action")).to eq("scheduler store migration not required")
    expect(descriptor.operator_summary.fetch("startup_checklist")).to eq("provide secrets via environment variable A3_SECRET; scheduler store migration not required")
    expect(descriptor.operator_summary.fetch("persistent_state_model")).to eq("scheduler_state_root=/tmp/runtime/state/scheduler task_repository_root=/tmp/runtime/state/tasks run_repository_root=/tmp/runtime/state/runs evidence_root=/tmp/runtime/state/evidence blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses artifact_owner_cache_root=/tmp/runtime/state/artifact_owner_cache logs_root=/tmp/runtime/state/logs workspace_root=/tmp/runtime/state/workspaces artifact_root=/tmp/runtime/state/artifacts")
    expect(descriptor.operator_summary.fetch("retention_policy")).to eq("terminal_workspace_cleanup=retention_policy_controlled blocked_evidence_retention=independent_from_scheduler_cleanup image_upgrade_cleanup_trigger=none")
    expect(descriptor.operator_summary.fetch("materialization_model")).to eq("repo_slot_namespace=task_workspace_fixed implementation_workspace=ticket_workspace review_workspace=runtime_workspace verification_workspace=runtime_workspace merge_workspace=runtime_workspace missing_repo_rescue=forbidden source_descriptor_alignment=required_before_phase_start")
    expect(descriptor.operator_summary.fetch("runtime_configuration_model")).to eq("project_config_path=required preset_dir=required storage_backend=required state_root=required workspace_root=required artifact_root=required repo_source_strategy=required repository_metadata=required authoritative_branch_resolution=required integration_target_resolution=required secret_reference=required")
    expect(descriptor.operator_summary.fetch("deployment_shape")).to eq("runtime_package=single_project writable_state=isolated scheduler_instance=single_project state_boundary=project secret_boundary=project")
    expect(descriptor.operator_summary.fetch("credential_boundary_model")).to eq("secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only")
    expect(descriptor.operator_summary.fetch("observability_boundary_model")).to eq("operator_logs_root=/tmp/runtime/state/logs blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses evidence_root=/tmp/runtime/state/evidence validation_output=stdout_only workspace_debug_reference=path_only")
    expect(descriptor.operator_summary.fetch("networking_boundary")).to eq("outbound=git,issue_api,package_registry,llm_gateway,verification_service secret_source=secret_store token_scope=project")
    expect(descriptor.operator_summary.fetch("upgrade_contract")).to eq("image_upgrade=independent project_config_schema_version=1 preset_schema_version=1 state_migration=explicit")
    expect(descriptor.operator_summary.fetch("fail_fast_policy")).to eq("project_config_schema_mismatch=fail_fast preset_schema_conflict=fail_fast writable_mount_missing=fail_fast secret_missing=fail_fast scheduler_store_migration_pending=fail_fast")
    expect(descriptor.operator_summary.fetch("execution_modes")).to eq("one_shot_cli=bin/a3 doctor-runtime /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state | bin/a3 migrate-scheduler-store /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state | bin/a3 execute-until-idle /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state ; scheduler_loop=bin/a3 execute-until-idle /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state ; doctor_inspect=bin/a3 doctor-runtime /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state")
    expect(descriptor.operator_summary.fetch("execution_mode_contract")).to eq("one_shot_cli=operator_driven_doctor_migration_runtime ; scheduler_loop=continuous_runnable_processing_after_runtime_ready ; doctor_inspect=configuration_and_mount_validation_only")
    expect(descriptor.operator_summary.fetch("descriptor_startup_readiness")).to eq("descriptor_ready")
    expect(descriptor.operator_summary.fetch("doctor_command")).to eq("bin/a3 doctor-runtime /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state")
    expect(descriptor.operator_summary.fetch("migration_command")).to eq("bin/a3 migrate-scheduler-store /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state")
    expect(descriptor.operator_summary.fetch("runtime_command")).to eq("bin/a3 execute-until-idle /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state")
    expect(descriptor.operator_summary.fetch("runtime_validation_command")).to eq("bin/a3 doctor-runtime /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state && bin/a3 execute-until-idle /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state")
    expect(descriptor.operator_summary.fetch("startup_sequence")).to eq("doctor=bin/a3 doctor-runtime /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state migrate=skip runtime=bin/a3 execute-until-idle /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state")
  end

  it "keeps agent source aliases as slot to alias contract without agent local paths" do
    descriptor = described_class.build(
      image_version: "a3:v2.1.0",
      manifest_path: "/tmp/runtime/project.yaml",
      preset_dir: "/tmp/runtime/presets",
      storage_backend: :sqlite,
      storage_dir: "/tmp/runtime/state",
      repo_sources: { repo_alpha: "/repos/alpha", repo_beta: "/repos/beta" },
      manifest_schema_version: "1",
      required_manifest_schema_version: "1",
      preset_chain: [],
      preset_schema_versions: {},
      required_preset_schema_version: "1",
      secret_reference: "A3_SECRET",
      agent_runtime_profile: "dev-env",
      agent_control_plane_url: "http://a3-runtime:7393",
      agent_profile_path: "/profiles/dev-env-agent.json",
      agent_source_aliases: {
        repo_alpha: "sample-catalog-service",
        repo_beta: "sample-storefront"
      },
      agent_workspace_cleanup_policy: :cleanup_after_job
    )

    expect(descriptor.agent_runtime_profile_summary.fetch("source_aliases")).to eq(
      "repo_alpha" => "sample-catalog-service",
      "repo_beta" => "sample-storefront"
    )
    expect(descriptor.agent_runtime_profile_summary.fetch("agent_command")).to eq("a3-agent -config /profiles/dev-env-agent.json")
    expect(descriptor.operator_summary.fetch("agent_runtime_profile")).to include("source_aliases=repo_alpha=sample-catalog-service,repo_beta=sample-storefront")
    expect(descriptor.operator_summary.fetch("agent_worker_gateway_options")).to include("--agent-source-alias repo_alpha=sample-catalog-service")
    expect(descriptor.operator_summary.fetch("agent_worker_gateway_options")).not_to include("/repos/alpha")
  end

  it "accepts an explicit distribution contract" do
    descriptor = described_class.build(
      image_version: "a3:v2.1.0",
      manifest_path: "/tmp/runtime/project.yaml",
      preset_dir: "/tmp/runtime/presets",
      storage_backend: :sqlite,
      storage_dir: "/tmp/runtime/state",
      repo_sources: {},
      manifest_schema_version: "1",
      required_manifest_schema_version: "1",
      preset_chain: [],
      preset_schema_versions: {},
      required_preset_schema_version: "1",
      distribution_image_ref: "ghcr.io/example/a3-engine:v2.1.0",
      runtime_entrypoint: "/opt/a3/bin/a3",
      doctor_entrypoint: "/opt/a3/bin/a3 doctor-runtime",
      migration_entrypoint: "/opt/a3/bin/a3 migrate-scheduler-store",
      secret_delivery_mode: :file_mount,
      secret_reference: "/run/secrets/a3-runtime",
      scheduler_store_migration_state: :applied
    )

    expect(descriptor.distribution_image_ref).to eq("ghcr.io/example/a3-engine:v2.1.0")
    expect(descriptor.runtime_entrypoint).to eq("/opt/a3/bin/a3")
    expect(descriptor.doctor_entrypoint).to eq("/opt/a3/bin/a3 doctor-runtime")
    expect(descriptor.migration_entrypoint).to eq("/opt/a3/bin/a3 migrate-scheduler-store")
    expect(descriptor.secret_delivery_mode).to eq(:file_mount)
    expect(descriptor.secret_reference).to eq("/run/secrets/a3-runtime")
    expect(descriptor.scheduler_store_migration_state).to eq(:applied)
    expect(descriptor.operator_summary.fetch("repo_source_action")).to eq("no repo source action required")
    expect(descriptor.operator_summary.fetch("operator_action")).to eq("provide secrets via mounted file /run/secrets/a3-runtime; scheduler store migration already applied")
  end

  it "derives operator guidance from runtime contract" do
    descriptor = described_class.build(
      image_version: "a3:v2.1.0",
      manifest_path: "/tmp/runtime/project.yaml",
      preset_dir: "/tmp/runtime/presets",
      storage_backend: :sqlite,
      storage_dir: "/tmp/runtime/state",
      repo_sources: {},
      manifest_schema_version: "0",
      required_manifest_schema_version: "1",
      preset_chain: [],
      preset_schema_versions: {},
      required_preset_schema_version: "1",
      secret_reference: "A3_SECRET",
      secret_delivery_mode: :environment_variable,
      scheduler_store_migration_state: :pending
    )

    expect(descriptor.operator_summary.fetch("runtime_contract")).to eq("project_config_schema_version=0 required_project_config_schema_version=1 required_preset_schema_version=1 preset_schema_versions= repo_source_strategy=none repo_source_slots= secret_delivery_mode=environment_variable secret_reference=A3_SECRET scheduler_store_migration_state=pending")
    expect(descriptor.operator_summary.fetch("operator_action")).to eq("update project.yaml schema to 1; provide secrets via environment variable A3_SECRET; apply scheduler store migration before startup")
    expect(descriptor.operator_summary.fetch("descriptor_startup_readiness")).to eq("operator_action_required")
    expect(descriptor.operator_summary.fetch("runtime_validation_command")).to eq("bin/a3 doctor-runtime /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state && bin/a3 migrate-scheduler-store /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state && bin/a3 execute-until-idle /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state")
    expect(descriptor.operator_summary.fetch("startup_sequence")).to eq("doctor=bin/a3 doctor-runtime /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state migrate=bin/a3 migrate-scheduler-store /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state runtime=bin/a3 execute-until-idle /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state")
    expect(descriptor.operator_summary.fetch("execution_mode_contract")).to eq("one_shot_cli=operator_driven_doctor_migration_runtime ; scheduler_loop=continuous_runnable_processing_after_runtime_ready ; doctor_inspect=configuration_and_mount_validation_only")
  end

  it "rejects an empty distribution contract" do
    expect do
      described_class.new(
        image_version: "a3:v2.1.0",
        manifest_path: "/tmp/runtime/project.yaml",
        project_runtime_root: "/tmp/runtime",
        preset_dir: "/tmp/runtime/presets",
        storage_backend: :sqlite,
        state_root: "/tmp/runtime/state",
        workspace_root: "/tmp/runtime/state/workspaces",
        artifact_root: "/tmp/runtime/state/artifacts",
        repo_source_strategy: :none,
        repo_source_slots: [],
        repo_sources: {},
        distribution_image_ref: "",
        runtime_entrypoint: "",
        doctor_entrypoint: "",
        migration_entrypoint: "",
        secret_delivery_mode: :environment_variable,
        secret_reference: "A3_SECRET",
        scheduler_store_migration_state: :not_required,
        manifest_schema_version: "1",
        required_manifest_schema_version: "1",
        preset_chain: [],
        preset_schema_versions: {},
        required_preset_schema_version: "1"
      )
    end.to raise_error(A3::Domain::ConfigurationError, /distribution_image_ref must be provided/)
  end
end
