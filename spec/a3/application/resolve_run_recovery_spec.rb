# frozen_string_literal: true

RSpec.describe A3::Application::ResolveRunRecovery do
  subject(:use_case) do
    described_class.new(
      plan_rerun: plan_rerun,
      build_scope_snapshot: build_scope_snapshot,
      build_artifact_owner: build_artifact_owner
    )
  end

  let(:plan_rerun) { A3::Application::PlanRerun.new }
  let(:build_scope_snapshot) { A3::Application::BuildScopeSnapshot.new }
  let(:build_artifact_owner) { A3::Application::BuildArtifactOwner.new }
  let(:runtime_package) { instance_double(A3::Domain::RuntimePackageDescriptor) }
  let(:doctor_result) do
    instance_double(
      A3::Application::DoctorRuntimeEnvironment::Result,
      execution_modes_summary: "one_shot_cli=bin/a3 doctor-runtime /tmp/project.yaml ; scheduler_loop=bin/a3 execute-until-idle /tmp/project.yaml ; doctor_inspect=bin/a3 doctor-runtime /tmp/project.yaml",
      execution_mode_contract_summary: "one_shot_cli=operator_driven_doctor_migration_runtime ; scheduler_loop=continuous_runnable_processing_after_runtime_ready ; doctor_inspect=configuration_and_mount_validation_only",
      contract_health: "project_config_schema=ok preset_schema=ok repo_sources=ok secret_delivery=ok scheduler_store_migration=ok",
      schema_action_summary: "no schema action required",
      preset_schema_action_summary: "no preset schema action required",
      repo_source_action_summary: "no repo source action required",
      secret_delivery_action_summary: "provide secrets via environment variable A3_SECRET",
      scheduler_store_migration_action_summary: "scheduler store migration not required",
      recommended_execution_mode: :doctor_inspect,
      recommended_execution_mode_reason: "runtime is not ready; use doctor_inspect until blockers are resolved",
      recommended_execution_mode_command: "bin/a3 doctor-runtime /tmp/project.yaml",
      doctor_command_summary: "bin/a3 doctor-runtime /tmp/project.yaml",
      runtime_command_summary: "bin/a3 execute-until-idle /tmp/project.yaml",
      operator_guidance: nil,
      next_command: nil,
      migration_command_summary: nil,
      runtime_validation_command_summary: nil,
      startup_sequence: nil,
      startup_blockers: nil,
      distribution_summary: {
        "persistent_state_model" => "scheduler_state_root=/tmp/runtime/state/scheduler task_repository_root=/tmp/runtime/state/tasks run_repository_root=/tmp/runtime/state/runs evidence_root=/tmp/runtime/state/evidence blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses artifact_owner_cache_root=/tmp/runtime/state/artifact_owner_cache logs_root=/tmp/runtime/state/logs workspace_root=/tmp/runtime/state/workspaces artifact_root=/tmp/runtime/state/artifacts",
        "retention_policy" => "terminal_workspace_cleanup=retention_policy_controlled blocked_evidence_retention=independent_from_scheduler_cleanup image_upgrade_cleanup_trigger=none",
        "materialization_model" => "repo_slot_namespace=task_workspace_fixed implementation_workspace=ticket_workspace review_workspace=runtime_workspace verification_workspace=runtime_workspace merge_workspace=runtime_workspace runtime_workspace_kind=logical_phase_workspace physical_workspace_layout=worker_gateway_mode_defined agent_materialized_runtime_workspace=per_run_materialized missing_repo_rescue=forbidden source_descriptor_alignment=required_before_phase_start",
        "runtime_configuration_model" => "project_config_path=required preset_dir=required storage_backend=required state_root=required workspace_root=required artifact_root=required repo_source_strategy=required repository_metadata=required authoritative_branch_resolution=required integration_target_resolution=required secret_reference=required",
        "repository_metadata_model" => "repository_metadata=runtime_package_scoped source_descriptor_ref_resolution=required review_target_resolution=evidence_driven",
        "branch_resolution_model" => "authoritative_branch_resolution=runtime_package_scoped integration_target_resolution=runtime_package_scoped branch_integration_inputs=required",
        "credential_boundary_model" => "secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only",
        "observability_boundary_model" => "operator_logs_root=/tmp/runtime/state/logs blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses evidence_root=/tmp/runtime/state/evidence validation_output=stdout_only workspace_debug_reference=path_only",
        "deployment_shape" => "runtime_package=single_project writable_state=isolated scheduler_instance=single_project state_boundary=project secret_boundary=project",
        "networking_boundary" => "outbound=git,issue_api,package_registry,llm_gateway,verification_service secret_source=secret_store token_scope=project",
        "upgrade_contract" => "image_upgrade=independent project_config_schema_version=1 preset_schema_version=1 state_migration=explicit",
        "fail_fast_policy" => "project_config_schema_mismatch=fail_fast preset_schema_conflict=fail_fast writable_mount_missing=fail_fast secret_missing=fail_fast scheduler_store_migration_pending=fail_fast"
      }
    )
  end

  before do
    allow(A3::Application::DoctorRuntimeEnvironment).to receive(:new).with(runtime_package: runtime_package).and_return(
      instance_double(A3::Application::DoctorRuntimeEnvironment, call: doctor_result)
    )
  end

  let(:task) do
    A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha, :repo_beta],
      status: :blocked,
      parent_ref: "A3-v2#3022"
    )
  end

  let(:run) do
    A3::Domain::Run.new(
      ref: "run-1",
      task_ref: task.ref,
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "head456",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha, :repo_beta],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :task,
        snapshot_version: "head456"
      ),
      terminal_outcome: :blocked
    )
  end

  it "returns the rerun decision and operator recovery for blocked runs" do
    result = use_case.call(task: task, run: run, runtime_package: runtime_package)

    expect(result.decision).to eq(:requires_operator_action)
    expect(result.recovery).to have_attributes(
      decision: :requires_operator_action,
      operator_action_required: true,
      package_expectation: :inspect_runtime_package,
      rerun_hint: "diagnose blocked state and choose a fresh rerun source"
    )
  end

  it "returns the rerun decision and retry recovery for matching intent" do
    retryable_run = A3::Domain::Run.new(
      ref: "run-2",
      task_ref: task.ref,
      phase: :verification,
      workspace_kind: :runtime_workspace,
      source_descriptor: run.evidence.source_descriptor,
      scope_snapshot: run.evidence.scope_snapshot,
      review_target: run.evidence.review_target,
      artifact_owner: run.evidence.artifact_owner,
      terminal_outcome: :retryable
    )

    result = use_case.call(task: task, run: retryable_run, runtime_package: runtime_package)

    expect(result.decision).to eq(:same_phase_retry)
      expect(result.recovery).to have_attributes(
        decision: :same_phase_retry,
        operator_action_required: false,
        package_expectation: :reuse_runtime_package,
        rerun_hint: "rerun the same phase with the current source and review target"
      )
  end

  it "enriches recovery with runtime package doctor guidance when provided" do
    runtime_package = instance_double(A3::Domain::RuntimePackageDescriptor)
    doctor_result = instance_double(
      A3::Application::DoctorRuntimeEnvironment::Result,
      execution_modes_summary: "one_shot_cli=bin/a3 doctor-runtime /tmp/project.yaml | bin/a3 migrate-scheduler-store /tmp/project.yaml | bin/a3 execute-until-idle /tmp/project.yaml ; scheduler_loop=bin/a3 execute-until-idle /tmp/project.yaml ; doctor_inspect=bin/a3 doctor-runtime /tmp/project.yaml",
      execution_mode_contract_summary: "one_shot_cli=operator_driven_doctor_migration_runtime ; scheduler_loop=continuous_runnable_processing_after_runtime_ready ; doctor_inspect=configuration_and_mount_validation_only",
      contract_health: "project_config_schema=ok preset_schema=ok repo_sources=ok secret_delivery=ok scheduler_store_migration=pending",
      schema_action_summary: "no schema action required",
      preset_schema_action_summary: "no preset schema action required",
      repo_source_action_summary: "no repo source action required",
      secret_delivery_action_summary: "provide secrets via environment variable A3_SECRET",
      scheduler_store_migration_action_summary: "apply scheduler store migration before startup",
      recommended_execution_mode: :one_shot_cli,
      recommended_execution_mode_reason: "scheduler store migration is the only startup blocker; use one_shot_cli to apply migration and continue startup",
      recommended_execution_mode_command: "bin/a3 doctor-runtime /tmp/project.yaml && bin/a3 migrate-scheduler-store /tmp/project.yaml && bin/a3 execute-until-idle /tmp/project.yaml",
      doctor_command_summary: "bin/a3 doctor-runtime /tmp/project.yaml",
      runtime_command_summary: "bin/a3 execute-until-idle /tmp/project.yaml",
      operator_guidance: "startup blocked by scheduler_store_migration; apply scheduler store migration before startup; run bin/a3 doctor-runtime /tmp/project.yaml",
      next_command: "bin/a3 migrate-scheduler-store /tmp/project.yaml",
      migration_command_summary: "bin/a3 migrate-scheduler-store /tmp/project.yaml",
      runtime_validation_command_summary: "bin/a3 doctor-runtime /tmp/project.yaml && bin/a3 migrate-scheduler-store /tmp/project.yaml && bin/a3 execute-until-idle /tmp/project.yaml",
      startup_sequence: "doctor=bin/a3 doctor-runtime /tmp/project.yaml migrate=bin/a3 migrate-scheduler-store /tmp/project.yaml runtime=bin/a3 execute-until-idle /tmp/project.yaml",
      startup_blockers: "scheduler_store_migration",
      distribution_summary: {
        "persistent_state_model" => "scheduler_state_root=/tmp/runtime/state/scheduler task_repository_root=/tmp/runtime/state/tasks run_repository_root=/tmp/runtime/state/runs evidence_root=/tmp/runtime/state/evidence blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses artifact_owner_cache_root=/tmp/runtime/state/artifact_owner_cache logs_root=/tmp/runtime/state/logs workspace_root=/tmp/runtime/state/workspaces artifact_root=/tmp/runtime/state/artifacts",
        "retention_policy" => "terminal_workspace_cleanup=retention_policy_controlled blocked_evidence_retention=independent_from_scheduler_cleanup image_upgrade_cleanup_trigger=none",
        "materialization_model" => "repo_slot_namespace=task_workspace_fixed implementation_workspace=ticket_workspace review_workspace=runtime_workspace verification_workspace=runtime_workspace merge_workspace=runtime_workspace runtime_workspace_kind=logical_phase_workspace physical_workspace_layout=worker_gateway_mode_defined agent_materialized_runtime_workspace=per_run_materialized missing_repo_rescue=forbidden source_descriptor_alignment=required_before_phase_start",
        "runtime_configuration_model" => "project_config_path=required preset_dir=required storage_backend=required state_root=required workspace_root=required artifact_root=required repo_source_strategy=required repository_metadata=required authoritative_branch_resolution=required integration_target_resolution=required secret_reference=required",
        "repository_metadata_model" => "repository_metadata=runtime_package_scoped source_descriptor_ref_resolution=required review_target_resolution=evidence_driven",
        "branch_resolution_model" => "authoritative_branch_resolution=runtime_package_scoped integration_target_resolution=runtime_package_scoped branch_integration_inputs=required",
        "credential_boundary_model" => "secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only",
        "observability_boundary_model" => "operator_logs_root=/tmp/runtime/state/logs blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses evidence_root=/tmp/runtime/state/evidence validation_output=stdout_only workspace_debug_reference=path_only",
        "deployment_shape" => "runtime_package=single_project writable_state=isolated scheduler_instance=single_project state_boundary=project secret_boundary=project",
        "networking_boundary" => "outbound=git,issue_api,package_registry,llm_gateway,verification_service secret_source=secret_store token_scope=project",
        "upgrade_contract" => "image_upgrade=independent project_config_schema_version=1 preset_schema_version=1 state_migration=explicit",
        "fail_fast_policy" => "project_config_schema_mismatch=fail_fast preset_schema_conflict=fail_fast writable_mount_missing=fail_fast secret_missing=fail_fast scheduler_store_migration_pending=fail_fast"
      }
    )
    allow(A3::Application::DoctorRuntimeEnvironment).to receive(:new).with(runtime_package: runtime_package).and_return(
      instance_double(A3::Application::DoctorRuntimeEnvironment, call: doctor_result)
    )

    result = use_case.call(task: task, run: run, runtime_package: runtime_package)

    expect(result.recovery).to have_attributes(
      runtime_package_guidance: "startup blocked by scheduler_store_migration; apply scheduler store migration before startup; run bin/a3 doctor-runtime /tmp/project.yaml",
      runtime_package_contract_health: "project_config_schema=ok preset_schema=ok repo_sources=ok secret_delivery=ok scheduler_store_migration=pending",
      runtime_package_execution_modes: "one_shot_cli=bin/a3 doctor-runtime /tmp/project.yaml | bin/a3 migrate-scheduler-store /tmp/project.yaml | bin/a3 execute-until-idle /tmp/project.yaml ; scheduler_loop=bin/a3 execute-until-idle /tmp/project.yaml ; doctor_inspect=bin/a3 doctor-runtime /tmp/project.yaml",
      runtime_package_execution_mode_contract: "one_shot_cli=operator_driven_doctor_migration_runtime ; scheduler_loop=continuous_runnable_processing_after_runtime_ready ; doctor_inspect=configuration_and_mount_validation_only",
      runtime_package_schema_action: "no schema action required",
      runtime_package_preset_schema_action: "no preset schema action required",
      runtime_package_repo_source_action: "no repo source action required",
      runtime_package_secret_delivery_action: "provide secrets via environment variable A3_SECRET",
      runtime_package_scheduler_store_migration_action: "apply scheduler store migration before startup",
      runtime_package_recommended_execution_mode: :one_shot_cli,
      runtime_package_recommended_execution_mode_reason: "scheduler store migration is the only startup blocker; use one_shot_cli to apply migration and continue startup",
      runtime_package_recommended_execution_mode_command: "bin/a3 doctor-runtime /tmp/project.yaml && bin/a3 migrate-scheduler-store /tmp/project.yaml && bin/a3 execute-until-idle /tmp/project.yaml",
      runtime_package_operator_action: :keep_inspecting,
      runtime_package_next_execution_mode: :doctor_inspect,
      runtime_package_next_execution_mode_reason: "runtime package still needs inspection before recovery can proceed",
      runtime_package_next_execution_mode_command: "bin/a3 doctor-runtime /tmp/project.yaml",
      runtime_package_next_command: "bin/a3 migrate-scheduler-store /tmp/project.yaml",
      runtime_package_migration_command: "bin/a3 migrate-scheduler-store /tmp/project.yaml",
      runtime_package_runtime_validation_command: "bin/a3 doctor-runtime /tmp/project.yaml && bin/a3 migrate-scheduler-store /tmp/project.yaml && bin/a3 execute-until-idle /tmp/project.yaml",
      runtime_package_startup_sequence: "doctor=bin/a3 doctor-runtime /tmp/project.yaml migrate=bin/a3 migrate-scheduler-store /tmp/project.yaml runtime=bin/a3 execute-until-idle /tmp/project.yaml",
      runtime_package_startup_blockers: "scheduler_store_migration",
      runtime_package_retention_policy: "terminal_workspace_cleanup=retention_policy_controlled blocked_evidence_retention=independent_from_scheduler_cleanup image_upgrade_cleanup_trigger=none",
      runtime_package_materialization_model: "repo_slot_namespace=task_workspace_fixed implementation_workspace=ticket_workspace review_workspace=runtime_workspace verification_workspace=runtime_workspace merge_workspace=runtime_workspace runtime_workspace_kind=logical_phase_workspace physical_workspace_layout=worker_gateway_mode_defined agent_materialized_runtime_workspace=per_run_materialized missing_repo_rescue=forbidden source_descriptor_alignment=required_before_phase_start",
      runtime_package_runtime_configuration_model: "project_config_path=required preset_dir=required storage_backend=required state_root=required workspace_root=required artifact_root=required repo_source_strategy=required repository_metadata=required authoritative_branch_resolution=required integration_target_resolution=required secret_reference=required",
      runtime_package_credential_boundary_model: "secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only",
      runtime_package_observability_boundary_model: "operator_logs_root=/tmp/runtime/state/logs blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses evidence_root=/tmp/runtime/state/evidence validation_output=stdout_only workspace_debug_reference=path_only"
    )
  end
end
