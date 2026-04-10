# frozen_string_literal: true

RSpec.describe A3::CLI::ShowOutputFormatter do
  def build_recovery_view(decision)
    case decision
    when :requires_operator_action
      A3::Domain::OperatorInspectionReadModel::RunView::RecoveryView.new(
        decision: :requires_operator_action,
        next_action: :diagnose_blocked,
        operator_action_required: true,
        summary: "blocked run requires operator action before rerun",
        rerun_hint: "diagnose blocked state and choose a fresh rerun source",
        package_expectation: :inspect_runtime_package,
        runtime_package_guidance: "run doctor-runtime and inspect repo sources, secret delivery, and scheduler store migration before rerun",
        runtime_package_contract_health: "manifest_schema=ok preset_schema=ok repo_sources=missing secret_delivery=missing scheduler_store_migration=ok",
        runtime_package_execution_modes: nil,
        runtime_package_execution_mode_contract: nil,
        runtime_package_schema_action: "no schema action required",
        runtime_package_preset_schema_action: "no preset schema action required",
        runtime_package_repo_source_action: "provide writable repo sources for repo_alpha",
        runtime_package_secret_delivery_action: "provide secrets via environment variable A3_SECRET",
        runtime_package_scheduler_store_migration_action: "scheduler store migration not required",
        runtime_package_recommended_execution_mode: :doctor_inspect,
        runtime_package_recommended_execution_mode_reason: "runtime contract is unavailable in this fixture",
        runtime_package_recommended_execution_mode_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
        runtime_package_operator_action: :keep_inspecting,
        runtime_package_operator_action_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
        runtime_package_next_execution_mode: :doctor_inspect,
        runtime_package_next_execution_mode_reason: "runtime package still needs inspection before recovery can proceed",
        runtime_package_next_execution_mode_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
        runtime_package_next_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
        runtime_package_doctor_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
        runtime_package_runtime_canary_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml && bin/a3 execute-until-idle /tmp/runtime/manifest.yml",
        runtime_package_startup_blockers: "repo_sources",
        runtime_package_migration_command: "bin/a3 migrate-scheduler-store /tmp/runtime/manifest.yml",
        runtime_package_runtime_command: "bin/a3 execute-until-idle /tmp/runtime/manifest.yml",
        runtime_package_startup_sequence: "doctor=bin/a3 doctor-runtime /tmp/runtime/manifest.yml migrate=skip runtime=bin/a3 execute-until-idle /tmp/runtime/manifest.yml",
        runtime_package_persistent_state_model: "scheduler_state_root=/tmp/runtime/state/scheduler",
        runtime_package_retention_policy: "terminal_workspace_cleanup=retention_policy_controlled",
        runtime_package_materialization_model: "repo_slot_namespace=task_workspace_fixed",
        runtime_package_runtime_configuration_model: "manifest_path=required",
        runtime_package_repository_metadata_model: "repository_metadata=runtime_package_scoped",
        runtime_package_branch_resolution_model: "authoritative_branch_resolution=runtime_package_scoped",
        runtime_package_credential_boundary_model: "secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only",
        runtime_package_observability_boundary_model: "operator_logs_root=/tmp/runtime/state/logs blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses evidence_root=/tmp/runtime/state/evidence canary_output=stdout_only workspace_debug_reference=path_only",
        runtime_package_deployment_shape: "runtime_package=single_project",
        runtime_package_networking_boundary: "outbound=git",
        runtime_package_upgrade_contract: "state_migration=explicit",
        runtime_package_fail_fast_policy: "manifest_schema_mismatch=fail_fast"
      )
    else
      raise ArgumentError, "unsupported recovery decision: #{decision}"
    end
  end

  it "delegates public task formatting through the task output facade" do
    task = instance_double("TaskView")

    expect(A3::CLI::ShowOutputFormatter::TaskOutput).to receive(:lines).with(task).and_return(["task"])

    expect(described_class.task_lines(task)).to eq(["task"])
  end

  it "delegates public run and blocked formatting through the run output facade" do
    run = instance_double("RunView")
    diagnosis = instance_double("BlockedDiagnosisResult")

    expect(A3::CLI::ShowOutputFormatter::RunOutput).to receive(:lines).with(run).and_return(["run"])
    expect(A3::CLI::ShowOutputFormatter::RunOutput).to receive(:blocked_diagnosis_lines).with(diagnosis).and_return(["blocked"])

    expect(described_class.run_lines(run)).to eq(["run"])
    expect(described_class.blocked_diagnosis_lines(diagnosis)).to eq(["blocked"])
  end

  it "formats blocked diagnosis lines with the raw worker response bundle when present" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#child",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: %i[repo_alpha repo_beta],
      status: :blocked,
      current_run_ref: "run-1",
      parent_ref: "A3-v2#parent"
    )
    run = A3::Domain::Run.new(
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
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
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
        task_ref: task.ref,
        run_ref: "run-1",
        phase: :review,
        outcome: :blocked,
        review_target: A3::Domain::ReviewTarget.new(
          base_commit: "base123",
          head_commit: "head456",
          task_ref: task.ref,
          phase_ref: :review
        ),
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :detached_commit,
          ref: "head456",
          task_ref: task.ref
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
    evidence_summary = A3::Domain::OperatorInspectionReadModel::EvidenceSummary.from_evidence(run.evidence)
    recovery = instance_double(
      "Recovery",
      decision: :requires_operator_action,
      next_action: :diagnose_blocked,
      operator_action_required: true,
      package_expectation: :inspect_runtime_package,
      runtime_package_guidance: "run doctor-runtime and inspect repo sources, secret delivery, and scheduler store migration before rerun",
      runtime_package_contract_health: "manifest_schema=ok preset_schema=ok repo_sources=missing secret_delivery=missing scheduler_store_migration=ok",
      runtime_package_execution_modes: "one_shot_cli=bin/a3 doctor-runtime /tmp/runtime/manifest.yml ; scheduler_loop=bin/a3 execute-until-idle /tmp/runtime/manifest.yml ; doctor_inspect=bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
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
      runtime_package_operator_action_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      runtime_package_next_execution_mode: :doctor_inspect,
      runtime_package_next_execution_mode_reason: "runtime package still needs inspection before recovery can proceed",
      runtime_package_next_execution_mode_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      runtime_package_next_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      runtime_package_doctor_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      runtime_package_migration_command: "bin/a3 migrate-scheduler-store /tmp/runtime/manifest.yml",
      runtime_package_runtime_command: "bin/a3 execute-until-idle /tmp/runtime/manifest.yml",
      runtime_package_runtime_canary_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml && bin/a3 execute-until-idle /tmp/runtime/manifest.yml",
      runtime_package_startup_sequence: "doctor=bin/a3 doctor-runtime /tmp/runtime/manifest.yml migrate=skip runtime=bin/a3 execute-until-idle /tmp/runtime/manifest.yml",
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
      runtime_package_fail_fast_policy: "manifest_schema_mismatch=fail_fast preset_schema_conflict=fail_fast writable_mount_missing=fail_fast secret_missing=fail_fast scheduler_store_migration_pending=fail_fast",
      rerun_hint: "diagnose blocked state and choose a fresh rerun source"
    )
    result = A3::Application::ShowBlockedDiagnosis::Result.new(
      task: task,
      run: run,
      diagnosis: A3::Domain::BlockedDiagnosis.new(
        task_ref: task.ref,
        run_ref: "run-1",
        phase: :review,
        outcome: :blocked,
        review_target: A3::Domain::ReviewTarget.new(
          base_commit: "base123",
          head_commit: "head456",
          task_ref: task.ref,
          phase_ref: :review
        ),
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :detached_commit,
          ref: "head456",
          task_ref: task.ref
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
      evidence_summary: evidence_summary,
      recovery: recovery,
      worker_response_bundle: {
        "success" => false,
        "summary" => "review blocked",
        "failing_command" => "codex exec --json -",
        "observed_state" => "repo-beta missing"
      }
    )

    result = described_class.blocked_diagnosis_lines(result)

    expect(result).to include("blocked diagnosis blocked for run-1 on A3-v2#child")
    expect(result).to include("worker_response_bundle={\"success\"=>false, \"summary\"=>\"review blocked\", \"failing_command\"=>\"codex exec --json -\", \"observed_state\"=>\"repo-beta missing\"}")
    expect(result).to include("recovery decision=requires_operator_action next_action=diagnose_blocked operator_action_required=true")
    expect(result).to include("runtime_package_action=inspect_runtime_package")
    expect(result).to include("runtime_package_guidance=run doctor-runtime and inspect repo sources, secret delivery, and scheduler store migration before rerun")
    expect(result).to include("runtime_package_execution_modes=one_shot_cli=bin/a3 doctor-runtime /tmp/runtime/manifest.yml ; scheduler_loop=bin/a3 execute-until-idle /tmp/runtime/manifest.yml ; doctor_inspect=bin/a3 doctor-runtime /tmp/runtime/manifest.yml")
    expect(result).to include("runtime_package_execution_mode_contract=one_shot_cli=operator_driven_doctor_migration_runtime ; scheduler_loop=continuous_runnable_processing_after_runtime_ready ; doctor_inspect=configuration_and_mount_validation_only")
    expect(result).to include("runtime_package_recommended_execution_mode=doctor_inspect")
    expect(result).to include("runtime_package_recommended_execution_mode_reason=runtime is not ready; use doctor_inspect until blockers are resolved")
    expect(result).to include("runtime_package_recommended_execution_mode_command=bin/a3 doctor-runtime /tmp/runtime/manifest.yml")
    expect(result).to include("runtime_package_operator_action=keep_inspecting")
    expect(result).to include("runtime_package_next_execution_mode=doctor_inspect")
    expect(result).to include("runtime_package_next_execution_mode_reason=runtime package still needs inspection before recovery can proceed")
    expect(result).to include("runtime_package_next_execution_mode_command=bin/a3 doctor-runtime /tmp/runtime/manifest.yml")
    expect(result).to include("runtime_package_next_command=bin/a3 doctor-runtime /tmp/runtime/manifest.yml")
    expect(result).to include("runtime_package_migration_command=bin/a3 migrate-scheduler-store /tmp/runtime/manifest.yml")
    expect(result).to include("runtime_package_runtime_canary_command=bin/a3 doctor-runtime /tmp/runtime/manifest.yml && bin/a3 execute-until-idle /tmp/runtime/manifest.yml")
    expect(result).to include("runtime_package_startup_sequence=doctor=bin/a3 doctor-runtime /tmp/runtime/manifest.yml migrate=skip runtime=bin/a3 execute-until-idle /tmp/runtime/manifest.yml")
    expect(result).to include("runtime_package_startup_blockers=repo_sources")
    expect(result).to include("runtime_package_persistent_state_model=scheduler_state_root=/tmp/runtime/state/scheduler task_repository_root=/tmp/runtime/state/tasks run_repository_root=/tmp/runtime/state/runs evidence_root=/tmp/runtime/state/evidence blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses artifact_owner_cache_root=/tmp/runtime/state/artifact_owner_cache logs_root=/tmp/runtime/state/logs workspace_root=/tmp/runtime/state/workspaces artifact_root=/tmp/runtime/state/artifacts")
    expect(result).to include("runtime_package_retention_policy=terminal_workspace_cleanup=retention_policy_controlled blocked_evidence_retention=independent_from_scheduler_cleanup image_upgrade_cleanup_trigger=none")
    expect(result).to include("runtime_package_materialization_model=repo_slot_namespace=task_workspace_fixed implementation_workspace=ticket_workspace review_workspace=runtime_workspace verification_workspace=runtime_workspace merge_workspace=runtime_workspace missing_repo_rescue=forbidden source_descriptor_alignment=required_before_phase_start")
    expect(result).to include("runtime_package_runtime_configuration_model=manifest_path=required preset_dir=required storage_backend=required state_root=required workspace_root=required artifact_root=required repo_source_strategy=required repository_metadata=required authoritative_branch_resolution=required integration_target_resolution=required secret_reference=required")
    expect(result).to include("runtime_package_deployment_shape=runtime_package=single_project writable_state=isolated scheduler_instance=single_project state_boundary=project secret_boundary=project")
    expect(result).to include("runtime_package_networking_boundary=outbound=git,issue_api,package_registry,llm_gateway,verification_service secret_source=secret_store token_scope=project")
    expect(result).to include("runtime_package_upgrade_contract=image_upgrade=independent manifest_schema_version=1 preset_schema_version=1 state_migration=explicit")
    expect(result).to include("runtime_package_fail_fast_policy=manifest_schema_mismatch=fail_fast preset_schema_conflict=fail_fast writable_mount_missing=fail_fast secret_missing=fail_fast scheduler_store_migration_pending=fail_fast")
    expect(result).to include("diagnostic.missing_path=/tmp/repo-beta")
  end

  it "formats blocked diagnosis application results with the same contract as read model snapshots" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#child",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: %i[repo_alpha repo_beta],
      status: :blocked,
      current_run_ref: "run-1",
      parent_ref: "A3-v2#parent"
    )
    run = A3::Domain::Run.new(
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
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
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
        task_ref: task.ref,
        run_ref: "run-1",
        phase: :review,
        outcome: :blocked,
        review_target: A3::Domain::ReviewTarget.new(
          base_commit: "base123",
          head_commit: "head456",
          task_ref: task.ref,
          phase_ref: :review
        ),
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :detached_commit,
          ref: "head456",
          task_ref: task.ref
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
    run_view = A3::Domain::OperatorInspectionReadModel::RunView.from_run(
      run,
      recovery: build_recovery_view(:requires_operator_action)
    )
    result = A3::Application::ShowBlockedDiagnosis::Result.new(
      task: task,
      run: run,
      diagnosis: run.phase_records.last.blocked_diagnosis,
      evidence_summary: run_view.evidence_summary,
      recovery: run_view.recovery,
      worker_response_bundle: {
        "success" => false,
        "summary" => "review blocked",
        "failing_command" => "codex exec --json -",
        "observed_state" => "repo-beta missing"
      }
    )

    lines = described_class.blocked_diagnosis_lines(result)

    expect(lines).to include("blocked diagnosis blocked for run-1 on A3-v2#child")
    expect(lines).to include("worker_response_bundle={\"success\"=>false, \"summary\"=>\"review blocked\", \"failing_command\"=>\"codex exec --json -\", \"observed_state\"=>\"repo-beta missing\"}")
    expect(lines).to include("recovery decision=requires_operator_action next_action=diagnose_blocked operator_action_required=true")
  end

  it "does not pull worker response bundle from a later non-blocked phase record" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#child",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: %i[repo_alpha repo_beta],
      status: :blocked,
      current_run_ref: "run-1",
      parent_ref: "A3-v2#parent"
    )
    run = A3::Domain::Run.new(
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
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
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
        task_ref: task.ref,
        run_ref: "run-1",
        phase: :review,
        outcome: :blocked,
        review_target: A3::Domain::ReviewTarget.new(
          base_commit: "base123",
          head_commit: "head456",
          task_ref: task.ref,
          phase_ref: :review
        ),
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :detached_commit,
          ref: "head456",
          task_ref: task.ref
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
      )
    ).append_phase_evidence(
      phase: :verification,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "head456",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :task
      ),
      execution_record: A3::Domain::PhaseExecutionRecord.new(
        summary: "later phase",
        diagnostics: {
          "worker_response_bundle" => {
            "success" => false,
            "summary" => "later phase bundle"
          }
        }
      )
    )
    evidence_summary = A3::Domain::OperatorInspectionReadModel::EvidenceSummary.from_evidence(run.evidence)
    recovery = instance_double(
      "Recovery",
      decision: :requires_operator_action,
      next_action: :diagnose_blocked,
      operator_action_required: true,
      package_expectation: :inspect_runtime_package,
      runtime_package_guidance: "run doctor-runtime and inspect repo sources, secret delivery, and scheduler store migration before rerun",
      runtime_package_contract_health: "manifest_schema=ok preset_schema=ok repo_sources=missing secret_delivery=missing scheduler_store_migration=ok",
      runtime_package_execution_modes: nil,
      runtime_package_execution_mode_contract: nil,
      runtime_package_schema_action: "no schema action required",
      runtime_package_preset_schema_action: "no preset schema action required",
      runtime_package_repo_source_action: "provide writable repo sources for repo_alpha",
      runtime_package_secret_delivery_action: "provide secrets via environment variable A3_SECRET",
      runtime_package_scheduler_store_migration_action: "scheduler store migration not required",
      runtime_package_recommended_execution_mode: :doctor_inspect,
      runtime_package_recommended_execution_mode_reason: "runtime contract is unavailable in this fixture",
      runtime_package_recommended_execution_mode_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      runtime_package_operator_action: :keep_inspecting,
      runtime_package_operator_action_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      runtime_package_next_execution_mode: :doctor_inspect,
      runtime_package_next_execution_mode_reason: "runtime package still needs inspection before recovery can proceed",
      runtime_package_next_execution_mode_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      runtime_package_next_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      runtime_package_doctor_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml",
      runtime_package_migration_command: "bin/a3 migrate-scheduler-store /tmp/runtime/manifest.yml",
      runtime_package_runtime_command: "bin/a3 execute-until-idle /tmp/runtime/manifest.yml",
      runtime_package_runtime_canary_command: "bin/a3 doctor-runtime /tmp/runtime/manifest.yml && bin/a3 execute-until-idle /tmp/runtime/manifest.yml",
      runtime_package_startup_sequence: "doctor=bin/a3 doctor-runtime /tmp/runtime/manifest.yml migrate=skip runtime=bin/a3 execute-until-idle /tmp/runtime/manifest.yml",
      runtime_package_startup_blockers: "repo_sources",
      runtime_package_persistent_state_model: "scheduler_state_root=/tmp/runtime/state/scheduler",
      runtime_package_retention_policy: "terminal_workspace_cleanup=retention_policy_controlled",
      runtime_package_materialization_model: "repo_slot_namespace=task_workspace_fixed",
      runtime_package_runtime_configuration_model: "manifest_path=required",
        runtime_package_repository_metadata_model: "repository_metadata=runtime_package_scoped",
        runtime_package_branch_resolution_model: "authoritative_branch_resolution=runtime_package_scoped",
        runtime_package_credential_boundary_model: "secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only",
        runtime_package_observability_boundary_model: "operator_logs_root=/tmp/runtime/state/logs blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses evidence_root=/tmp/runtime/state/evidence canary_output=stdout_only workspace_debug_reference=path_only",
        runtime_package_deployment_shape: "runtime_package=single_project",
      runtime_package_networking_boundary: "outbound=git",
      runtime_package_upgrade_contract: "state_migration=explicit",
      runtime_package_fail_fast_policy: "manifest_schema_mismatch=fail_fast",
      rerun_hint: "diagnose blocked state and choose a fresh rerun source"
    )
    result = A3::Application::ShowBlockedDiagnosis::Result.new(
      task: task,
      run: run,
      diagnosis: run.phase_records.find(&:blocked_diagnosis).blocked_diagnosis,
      evidence_summary: evidence_summary,
      recovery: recovery
    )

    lines = described_class.blocked_diagnosis_lines(result)

    expect(lines.none? { |line| line.start_with?("worker_response_bundle=") }).to eq(true)
  end

  it "delegates public scheduler formatting through the scheduler output facade" do
    history = instance_double("SchedulerHistory")

    expect(A3::CLI::ShowOutputFormatter::SchedulerOutput).to receive(:history_lines).with(history).and_return(["scheduler"])

    expect(described_class.scheduler_history_lines(history)).to eq(["scheduler"])
  end

  it "formats task lines through the task formatter" do
    parent = A3::Domain::Task.new(
      ref: "A3-v2#parent",
      kind: :parent,
      edit_scope: [:repo_alpha],
      status: :in_review
    )
    child = A3::Domain::Task.new(
      ref: "A3-v2#child",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: %i[repo_alpha repo_beta],
      status: :blocked,
      current_run_ref: "run-1",
      parent_ref: parent.ref
    )
    task_view = A3::Domain::OperatorInspectionReadModel::TaskView.from_task(task: child, tasks: [parent, child])

    result = described_class.task_lines(task_view)

    expect(result).to include("task A3-v2#child kind=child status=blocked current_run=run-1")
    expect(result).to include("runnable_reason=already_running")
    expect(result).to include("parent=A3-v2#parent status=in_review current_run=")
  end

  it "formats run lines through the run formatter" do
    run = A3::Domain::Run.new(
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
        review_target: nil,
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
    run_view = A3::Domain::OperatorInspectionReadModel::RunView.from_run(
      run,
      recovery: build_recovery_view(:requires_operator_action)
    )

    result = described_class.run_lines(run_view)

    expect(result).to include("run run-1 task=A3-v2#child phase=verification workspace=runtime_workspace source=detached_commit:head456 outcome=blocked")
    expect(result).to include("latest_execution phase=verification summary=review launch could not resolve runtime workspace")
    expect(result).to include("worker_response_bundle={\"success\"=>false, \"summary\"=>\"review blocked\", \"failing_command\"=>\"codex exec --json -\", \"observed_state\"=>\"repo-beta missing\"}")
    expect(result).to include("runtime_package_action=inspect_runtime_package")
    expect(result).to include("runtime_package_guidance=run doctor-runtime and inspect repo sources, secret delivery, and scheduler store migration before rerun")
    expect(result).to include("runtime merge_target=merge_to_parent merge_policy=ff_only")
    expect(result).to include("blocked_diagnostic.missing_path=/tmp/repo-beta")
  end

  it "formats scheduler history lines through the scheduler formatter" do
    history = A3::Domain::OperatorInspectionReadModel::SchedulerHistory.from_cycles(
      [
        A3::Domain::SchedulerCycle.new(
          cycle_number: 1,
          executed_count: 2,
          executed_steps: [
            A3::Domain::SchedulerCycleStep.new(task_ref: "A3-v2#3030", phase: :implementation)
          ],
          idle_reached: true,
          stop_reason: :idle,
          quarantined_count: 1
        )
      ]
    )

    result = described_class.scheduler_history_lines(history)

    expect(result).to eq(
      ["cycle=1 executed=2 idle=true stop_reason=idle quarantined=1 steps=A3-v2#3030:implementation"]
    )
  end

  it "formats implementation-side review evidence in run lines" do
    run_view = A3::Domain::OperatorInspectionReadModel::RunView.new(
      ref: "run-impl-1",
      task_ref: "A3-v2#child",
      task_kind: :child,
      phase: :implementation,
      workspace_kind: :ticket_workspace,
      source_type: :branch_head,
      source_ref: "refs/heads/a3/work/child",
      terminal_outcome: :completed,
      evidence_summary: A3::Domain::OperatorInspectionReadModel::EvidenceSummary.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        source_ref: "refs/heads/a3/work/child",
        review_base: "base123",
        review_head: "head456",
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :task,
        artifact_owner_ref: "A3-v2#child",
        artifact_owner_scope: :task,
        artifact_snapshot_version: "head456",
        phase_records_count: 1
      ),
      latest_execution: A3::Domain::OperatorInspectionReadModel::RunView::ExecutionSnapshot.new(
        phase: :implementation,
        summary: "implementation completed",
        verification_summary: nil,
        failing_command: nil,
        observed_state: nil,
        diagnostics: {},
        worker_response_bundle: nil,
        runtime_snapshot: nil,
        review_disposition: {
          "kind" => "completed",
          "repo_scope" => "repo_alpha",
          "summary" => "No findings",
          "description" => "Implementation finished and final self-review found no outstanding issues.",
          "finding_key" => "completed-no-findings"
        }
      ),
      latest_blocked_diagnosis: nil,
      rerun_decision: :same_phase_retry,
      recovery: nil
    )

    result = described_class.run_lines(run_view)

    expect(result).to include("review_disposition kind=completed repo_scope=repo_alpha finding_key=completed-no-findings")
    expect(result).to include("review_disposition_summary=No findings")
    expect(result).to include("review_disposition_description=Implementation finished and final self-review found no outstanding issues.")
  end
end
