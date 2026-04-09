# frozen_string_literal: true

RSpec.describe A3::Application::ShowRun do
  subject(:use_case) do
    described_class.new(
      run_repository: run_repository,
      task_repository: task_repository,
      plan_rerun: plan_rerun,
      build_scope_snapshot: build_scope_snapshot,
      build_artifact_owner: build_artifact_owner
    )
  end

  let(:run_repository) { A3::Infra::InMemoryRunRepository.new }
  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:plan_rerun) { A3::Application::PlanRerun.new }
  let(:build_scope_snapshot) { A3::Application::BuildScopeSnapshot.new }
  let(:build_artifact_owner) { A3::Application::BuildArtifactOwner.new }
  let(:runtime_package) { instance_double(A3::Domain::RuntimePackageDescriptor) }
  let(:doctor_result) do
    instance_double(
      A3::Application::DoctorRuntimeEnvironment::Result,
      execution_modes_summary: "one_shot_cli=bin/a3 doctor-runtime /tmp/runtime/manifest.yml | bin/a3 migrate-scheduler-store /tmp/runtime/manifest.yml | bin/a3 execute-until-idle /tmp/runtime/manifest.yml ; scheduler_loop=bin/a3 execute-until-idle /tmp/runtime/manifest.yml ; doctor_inspect=bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      contract_health: "manifest_schema=ok preset_schema=ok repo_sources=ok secret_delivery=ok scheduler_store_migration=ok",
      operator_guidance: "run doctor-runtime and inspect repo sources, secret delivery, and scheduler store migration before rerun",
      schema_action_summary: "no schema action required",
      preset_schema_action_summary: "no preset schema action required",
      repo_source_action_summary: "no repo source action required",
      secret_delivery_action_summary: "provide secrets via environment variable A3_SECRET",
      scheduler_store_migration_action_summary: "scheduler store migration not required",
      next_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      migration_command_summary: "bin/a3 migrate-scheduler-store /tmp/runtime/manifest.yml",
      runtime_canary_command_summary: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      startup_sequence: "doctor=bin/a3 doctor-runtime /tmp/runtime/manifest.yml migrate=blocked runtime=blocked",
      startup_blockers: "repo_sources",
      execution_mode_contract_summary: "one_shot_cli=operator_driven_doctor_migration_runtime ; scheduler_loop=continuous_runnable_processing_after_runtime_ready ; doctor_inspect=configuration_and_mount_validation_only",
      recommended_execution_mode: :doctor_inspect,
      recommended_execution_mode_reason: "runtime is not ready; use doctor_inspect until blockers are resolved",
      recommended_execution_mode_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      doctor_command_summary: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      runtime_command_summary: "bin/a3 execute-until-idle /tmp/runtime/manifest.yml",
      distribution_summary: {
        "persistent_state_model" => "scheduler_state_root=/tmp/runtime/state/scheduler task_repository_root=/tmp/runtime/state/tasks run_repository_root=/tmp/runtime/state/runs evidence_root=/tmp/runtime/state/evidence blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses artifact_owner_cache_root=/tmp/runtime/state/artifact_owner_cache logs_root=/tmp/runtime/state/logs workspace_root=/tmp/runtime/state/workspaces artifact_root=/tmp/runtime/state/artifacts",
        "retention_policy" => "terminal_workspace_cleanup=retention_policy_controlled blocked_evidence_retention=independent_from_scheduler_cleanup image_upgrade_cleanup_trigger=none",
        "materialization_model" => "repo_slot_namespace=task_workspace_fixed implementation_workspace=ticket_workspace review_workspace=runtime_workspace verification_workspace=runtime_workspace merge_workspace=runtime_workspace missing_repo_rescue=forbidden source_descriptor_alignment=required_before_phase_start",
        "runtime_configuration_model" => "manifest_path=required preset_dir=required storage_backend=required state_root=required workspace_root=required artifact_root=required repo_source_strategy=required repository_metadata=required authoritative_branch_resolution=required integration_target_resolution=required secret_reference=required",
        "repository_metadata_model" => "repository_metadata=runtime_package_scoped source_descriptor_ref_resolution=required review_target_resolution=evidence_driven",
        "branch_resolution_model" => "authoritative_branch_resolution=runtime_package_scoped integration_target_resolution=runtime_package_scoped branch_integration_inputs=required",
        "credential_boundary_model" => "secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only",
        "observability_boundary_model" => "operator_logs_root=/tmp/runtime/state/logs blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses evidence_root=/tmp/runtime/state/evidence canary_output=stdout_only workspace_debug_reference=path_only",
        "deployment_shape" => "runtime_package=single_project writable_state=isolated scheduler_instance=single_project state_boundary=project secret_boundary=project",
        "networking_boundary" => "outbound=git,issue_api,package_registry,llm_gateway,verification_service secret_source=secret_store token_scope=project",
        "upgrade_contract" => "image_upgrade=independent manifest_schema_version=1 preset_schema_version=1 state_migration=explicit",
        "fail_fast_policy" => "manifest_schema_mismatch=fail_fast preset_schema_conflict=fail_fast writable_mount_missing=fail_fast secret_missing=fail_fast scheduler_store_migration_pending=fail_fast"
      }
    )
  end

  before do
    allow(A3::Application::DoctorRuntimeEnvironment).to receive(:new).with(runtime_package: runtime_package).and_return(
      instance_double(A3::Application::DoctorRuntimeEnvironment, call: doctor_result)
    )
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#child",
        kind: :child,
        edit_scope: [:repo_alpha],
        verification_scope: %i[repo_alpha repo_beta],
        status: :blocked,
        parent_ref: "A3-v2#parent"
      )
    )
    run_repository.save(
      A3::Domain::Run.new(
        ref: "run-1",
        task_ref: "A3-v2#child",
        phase: :review,
        workspace_kind: :runtime_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :detached_commit,
          ref: "head456",
          task_ref: "A3-v2#child"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_alpha],
          verification_scope: %i[repo_alpha repo_beta],
          ownership_scope: :task
        ),
        review_target: A3::Domain::ReviewTarget.new(
          base_commit: "base123",
          head_commit: "head456",
          task_ref: "A3-v2#child",
          phase_ref: :review
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "A3-v2#parent",
          owner_scope: :task,
          snapshot_version: "head456"
        ),
        terminal_outcome: :blocked
      ).append_blocked_diagnosis(
        A3::Domain::BlockedDiagnosis.new(
          task_ref: "A3-v2#child",
          run_ref: "run-1",
          phase: :review,
          outcome: :blocked,
          review_target: A3::Domain::ReviewTarget.new(
            base_commit: "base123",
            head_commit: "head456",
            task_ref: "A3-v2#child",
            phase_ref: :review
          ),
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :runtime_workspace,
            source_type: :detached_commit,
            ref: "head456",
            task_ref: "A3-v2#child"
          ),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(
            edit_scope: [:repo_alpha],
            verification_scope: %i[repo_alpha repo_beta],
            ownership_scope: :task
          ),
          artifact_owner: A3::Domain::ArtifactOwner.new(
            owner_ref: "A3-v2#parent",
            owner_scope: :task,
            snapshot_version: "head456"
          ),
          expected_state: "runtime workspace available",
          observed_state: "repo-beta missing",
          failing_command: "codex exec --json -",
          diagnostic_summary: "review launch could not resolve runtime workspace",
          infra_diagnostics: { "missing_path" => "/tmp/repo-beta" }
        ),
        execution_record: A3::Domain::PhaseExecutionRecord.new(
          summary: "review launch could not resolve runtime workspace",
          failing_command: "codex exec --json -",
          observed_state: "repo-beta missing",
          diagnostics: {
            "missing_path" => "/tmp/repo-beta",
            "worker_response_bundle" => {
              "success" => false,
              "summary" => "review blocked",
              "failing_command" => "codex exec --json -",
              "observed_state" => "repo-beta missing"
            }
          },
          runtime_snapshot: A3::Domain::PhaseRuntimeSnapshot.new(
            task_kind: :child,
            repo_scope: :repo_alpha,
            phase: :review,
            implementation_skill: "sample-implementation",
            review_skill: "sample-review",
            verification_commands: ["commands/check-style", "commands/verify-all"],
            remediation_commands: ["commands/apply-remediation"],
            workspace_hook: "sample-bootstrap",
            merge_target: :merge_to_parent,
            merge_policy: :ff_only
          )
        )
      )
    )
  end

  it "returns operator-facing run view with evidence summary" do
    result = use_case.call(run_ref: "run-1", runtime_package: runtime_package)

    expect(result.ref).to eq("run-1")
    expect(result.task_ref).to eq("A3-v2#child")
    expect(result.phase).to eq(:review)
    expect(result.workspace_kind).to eq(:runtime_workspace)
    expect(result.source_type).to eq(:detached_commit)
    expect(result.source_ref).to eq("head456")
    expect(result.terminal_outcome).to eq(:blocked)
    expect(result.rerun_decision).to eq(:requires_operator_action)
    expect(result.evidence_summary.review_base).to eq("base123")
    expect(result.evidence_summary.review_head).to eq("head456")
    expect(result.evidence_summary.phase_records_count).to eq(2)
    expect(result.latest_execution.phase).to eq(:review)
    expect(result.latest_execution.summary).to eq("review launch could not resolve runtime workspace")
    expect(result.latest_execution.verification_summary).to be_nil
    expect(result.latest_execution.failing_command).to eq("codex exec --json -")
    expect(result.latest_execution.observed_state).to eq("repo-beta missing")
    expect(result.latest_execution.diagnostics).to eq(
      "missing_path" => "/tmp/repo-beta",
      "worker_response_bundle" => {
        "success" => false,
        "summary" => "review blocked",
        "failing_command" => "codex exec --json -",
        "observed_state" => "repo-beta missing"
      }
    )
    expect(result.latest_execution.worker_response_bundle).to eq(
      "success" => false,
      "summary" => "review blocked",
      "failing_command" => "codex exec --json -",
      "observed_state" => "repo-beta missing"
    )
    expect(result.latest_execution.runtime_snapshot).to have_attributes(
      task_kind: :child,
      repo_scope: :repo_alpha,
      verification_commands: ["commands/check-style", "commands/verify-all"],
      remediation_commands: ["commands/apply-remediation"],
      workspace_hook: "sample-bootstrap",
      merge_target: :merge_to_parent
    )
    expect(result.latest_blocked_diagnosis).to have_attributes(
      phase: :review,
      summary: "review launch could not resolve runtime workspace",
      expected_state: "runtime workspace available",
      observed_state: "repo-beta missing",
      failing_command: "codex exec --json -",
      infra_diagnostics: { "missing_path" => "/tmp/repo-beta" }
    )
    expect(result.recovery).to have_attributes(
      decision: :requires_operator_action,
      next_action: :diagnose_blocked,
      operator_action_required: true,
      package_expectation: :inspect_runtime_package,
      summary: "blocked run requires operator action before rerun",
      rerun_hint: "diagnose blocked state and choose a fresh rerun source",
      runtime_package_guidance: "run doctor-runtime and inspect repo sources, secret delivery, and scheduler store migration before rerun"
    )
    expect(result.recovery.package_expectation).to eq(:inspect_runtime_package)
  end

  it "returns same-phase retry recovery for non-terminal runs with matching intent" do
    run_repository.save(
      A3::Domain::Run.new(
        ref: "run-2",
        task_ref: "A3-v2#child",
        phase: :verification,
        workspace_kind: :runtime_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :detached_commit,
          ref: "head789",
          task_ref: "A3-v2#child"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_alpha],
          verification_scope: %i[repo_alpha repo_beta],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "A3-v2#parent",
          owner_scope: :task,
          snapshot_version: "head789"
        )
      )
    )

    result = use_case.call(run_ref: "run-2", runtime_package: runtime_package)

      expect(result.recovery).to have_attributes(
        decision: :same_phase_retry,
        next_action: :retry_current_phase,
        operator_action_required: false,
        package_expectation: :reuse_runtime_package,
        summary: "same phase can be retried with the current evidence",
        rerun_hint: "rerun the same phase with the current source and review target",
        runtime_package_guidance: "run doctor-runtime and inspect repo sources, secret delivery, and scheduler store migration before rerun"
      )
  end

  it "adds runtime package recovery commands when runtime package is provided" do
    runtime_package = instance_double(A3::Domain::RuntimePackageDescriptor)
    doctor_result = instance_double(
      A3::Application::DoctorRuntimeEnvironment::Result,
      execution_modes_summary: "one_shot_cli=bin/a3 doctor-runtime /tmp/runtime/manifest.yml | bin/a3 migrate-scheduler-store /tmp/runtime/manifest.yml | bin/a3 execute-until-idle /tmp/runtime/manifest.yml ; scheduler_loop=bin/a3 execute-until-idle /tmp/runtime/manifest.yml ; doctor_inspect=bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      execution_mode_contract_summary: "one_shot_cli=operator_driven_doctor_migration_runtime ; scheduler_loop=continuous_runnable_processing_after_runtime_ready ; doctor_inspect=configuration_and_mount_validation_only",
      contract_health: "manifest_schema=ok preset_schema=ok repo_sources=missing secret_delivery=ok scheduler_store_migration=ok",
      schema_action_summary: "no schema action required",
      preset_schema_action_summary: "no preset schema action required",
      repo_source_action_summary: "provide writable repo sources for repo_alpha",
      secret_delivery_action_summary: "provide secrets via environment variable A3_SECRET",
      scheduler_store_migration_action_summary: "scheduler store migration not required",
      recommended_execution_mode: :doctor_inspect,
      recommended_execution_mode_reason: "runtime is not ready; use doctor_inspect until blockers are resolved",
      recommended_execution_mode_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      doctor_command_summary: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      runtime_command_summary: "bin/a3 execute-until-idle /tmp/runtime/manifest.yml",
      operator_guidance: "startup blocked by repo_sources; provide writable repo sources for repo_alpha; run bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      next_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      migration_command_summary: "bin/a3 migrate-scheduler-store /tmp/runtime/manifest.yml",
      runtime_canary_command_summary: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      startup_sequence: "doctor=bin/a3 doctor-runtime /tmp/runtime/manifest.yml migrate=blocked runtime=blocked",
      startup_blockers: "repo_sources",
      distribution_summary: {
        "persistent_state_model" => "scheduler_state_root=/tmp/runtime/state/scheduler task_repository_root=/tmp/runtime/state/tasks run_repository_root=/tmp/runtime/state/runs evidence_root=/tmp/runtime/state/evidence blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses artifact_owner_cache_root=/tmp/runtime/state/artifact_owner_cache logs_root=/tmp/runtime/state/logs workspace_root=/tmp/runtime/state/workspaces artifact_root=/tmp/runtime/state/artifacts",
        "retention_policy" => "terminal_workspace_cleanup=retention_policy_controlled blocked_evidence_retention=independent_from_scheduler_cleanup image_upgrade_cleanup_trigger=none",
        "materialization_model" => "repo_slot_namespace=task_workspace_fixed implementation_workspace=ticket_workspace review_workspace=runtime_workspace verification_workspace=runtime_workspace merge_workspace=runtime_workspace missing_repo_rescue=forbidden source_descriptor_alignment=required_before_phase_start",
        "runtime_configuration_model" => "manifest_path=required preset_dir=required storage_backend=required state_root=required workspace_root=required artifact_root=required repo_source_strategy=required repository_metadata=required authoritative_branch_resolution=required integration_target_resolution=required secret_reference=required",
        "repository_metadata_model" => "repository_metadata=runtime_package_scoped source_descriptor_ref_resolution=required review_target_resolution=evidence_driven",
        "branch_resolution_model" => "authoritative_branch_resolution=runtime_package_scoped integration_target_resolution=runtime_package_scoped branch_integration_inputs=required",
        "credential_boundary_model" => "secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only",
        "observability_boundary_model" => "operator_logs_root=/tmp/runtime/state/logs blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses evidence_root=/tmp/runtime/state/evidence canary_output=stdout_only workspace_debug_reference=path_only",
        "deployment_shape" => "runtime_package=single_project writable_state=isolated scheduler_instance=single_project state_boundary=project secret_boundary=project",
        "networking_boundary" => "outbound=git,issue_api,package_registry,llm_gateway,verification_service secret_source=secret_store token_scope=project",
        "upgrade_contract" => "image_upgrade=independent manifest_schema_version=1 preset_schema_version=1 state_migration=explicit",
        "fail_fast_policy" => "manifest_schema_mismatch=fail_fast preset_schema_conflict=fail_fast writable_mount_missing=fail_fast secret_missing=fail_fast scheduler_store_migration_pending=fail_fast"
      }
    )
    allow(A3::Application::DoctorRuntimeEnvironment).to receive(:new).with(runtime_package: runtime_package).and_return(
      instance_double(A3::Application::DoctorRuntimeEnvironment, call: doctor_result)
    )

    result = use_case.call(run_ref: "run-1", runtime_package: runtime_package)

    expect(result.recovery).to have_attributes(
      runtime_package_guidance: "startup blocked by repo_sources; provide writable repo sources for repo_alpha; run bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      runtime_package_contract_health: "manifest_schema=ok preset_schema=ok repo_sources=missing secret_delivery=ok scheduler_store_migration=ok",
      runtime_package_execution_modes: "one_shot_cli=bin/a3 doctor-runtime /tmp/runtime/manifest.yml | bin/a3 migrate-scheduler-store /tmp/runtime/manifest.yml | bin/a3 execute-until-idle /tmp/runtime/manifest.yml ; scheduler_loop=bin/a3 execute-until-idle /tmp/runtime/manifest.yml ; doctor_inspect=bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      runtime_package_execution_mode_contract: "one_shot_cli=operator_driven_doctor_migration_runtime ; scheduler_loop=continuous_runnable_processing_after_runtime_ready ; doctor_inspect=configuration_and_mount_validation_only",
      runtime_package_schema_action: "no schema action required",
      runtime_package_preset_schema_action: "no preset schema action required",
      runtime_package_repo_source_action: "provide writable repo sources for repo_alpha",
      runtime_package_secret_delivery_action: "provide secrets via environment variable A3_SECRET",
      runtime_package_scheduler_store_migration_action: "scheduler store migration not required",
      runtime_package_recommended_execution_mode: :doctor_inspect,
      runtime_package_recommended_execution_mode_reason: "runtime is not ready; use doctor_inspect until blockers are resolved",
      runtime_package_recommended_execution_mode_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      runtime_package_operator_action: :keep_inspecting,
      runtime_package_next_execution_mode: :doctor_inspect,
      runtime_package_next_execution_mode_reason: "runtime package still needs inspection before recovery can proceed",
      runtime_package_next_execution_mode_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      runtime_package_next_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      runtime_package_doctor_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      runtime_package_migration_command: "bin/a3 migrate-scheduler-store /tmp/runtime/manifest.yml",
      runtime_package_runtime_command: "bin/a3 execute-until-idle /tmp/runtime/manifest.yml",
      runtime_package_runtime_canary_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      runtime_package_startup_sequence: "doctor=bin/a3 doctor-runtime /tmp/runtime/manifest.yml migrate=blocked runtime=blocked",
      runtime_package_startup_blockers: "repo_sources",
      runtime_package_persistent_state_model: "scheduler_state_root=/tmp/runtime/state/scheduler task_repository_root=/tmp/runtime/state/tasks run_repository_root=/tmp/runtime/state/runs evidence_root=/tmp/runtime/state/evidence blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses artifact_owner_cache_root=/tmp/runtime/state/artifact_owner_cache logs_root=/tmp/runtime/state/logs workspace_root=/tmp/runtime/state/workspaces artifact_root=/tmp/runtime/state/artifacts",
      runtime_package_retention_policy: "terminal_workspace_cleanup=retention_policy_controlled blocked_evidence_retention=independent_from_scheduler_cleanup image_upgrade_cleanup_trigger=none",
      runtime_package_materialization_model: "repo_slot_namespace=task_workspace_fixed implementation_workspace=ticket_workspace review_workspace=runtime_workspace verification_workspace=runtime_workspace merge_workspace=runtime_workspace missing_repo_rescue=forbidden source_descriptor_alignment=required_before_phase_start",
      runtime_package_runtime_configuration_model: "manifest_path=required preset_dir=required storage_backend=required state_root=required workspace_root=required artifact_root=required repo_source_strategy=required repository_metadata=required authoritative_branch_resolution=required integration_target_resolution=required secret_reference=required",
      runtime_package_repository_metadata_model: "repository_metadata=runtime_package_scoped source_descriptor_ref_resolution=required review_target_resolution=evidence_driven",
      runtime_package_branch_resolution_model: "authoritative_branch_resolution=runtime_package_scoped integration_target_resolution=runtime_package_scoped branch_integration_inputs=required",
      runtime_package_credential_boundary_model: "secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only",
      runtime_package_observability_boundary_model: "operator_logs_root=/tmp/runtime/state/logs blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses evidence_root=/tmp/runtime/state/evidence canary_output=stdout_only workspace_debug_reference=path_only",
      runtime_package_deployment_shape: "runtime_package=single_project writable_state=isolated scheduler_instance=single_project state_boundary=project secret_boundary=project",
      runtime_package_networking_boundary: "outbound=git,issue_api,package_registry,llm_gateway,verification_service secret_source=secret_store token_scope=project",
      runtime_package_upgrade_contract: "image_upgrade=independent manifest_schema_version=1 preset_schema_version=1 state_migration=explicit",
      runtime_package_fail_fast_policy: "manifest_schema_mismatch=fail_fast preset_schema_conflict=fail_fast writable_mount_missing=fail_fast secret_missing=fail_fast scheduler_store_migration_pending=fail_fast"
    )
  end

  it "keeps latest blocked diagnosis when a later phase record has no blocked diagnosis" do
    later_phase_run = run_repository.fetch("run-1").append_phase_evidence(
      phase: :verification,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "head456",
        task_ref: "A3-v2#child"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :task
      ),
      execution_record: A3::Domain::PhaseExecutionRecord.new(
        summary: "later verification phase",
        diagnostics: {
          "worker_response_bundle" => {
            "success" => false,
            "summary" => "later phase bundle"
          }
        }
      )
    )
    run_repository.save(later_phase_run)

    result = use_case.call(run_ref: "run-1", runtime_package: runtime_package)

    expect(result.latest_execution.phase).to eq(:verification)
    expect(result.latest_execution.worker_response_bundle).to eq(
      "success" => false,
      "summary" => "later phase bundle"
    )
    expect(result.latest_blocked_diagnosis).to have_attributes(
      phase: :review,
      observed_state: "repo-beta missing",
      worker_response_bundle: {
        "success" => false,
        "summary" => "review blocked",
        "failing_command" => "codex exec --json -",
        "observed_state" => "repo-beta missing"
      }
    )
  end
end
