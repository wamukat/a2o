# frozen_string_literal: true

RSpec.describe A3::Domain::OperatorInspectionReadModel do
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
    when :requires_new_implementation
      A3::Domain::OperatorInspectionReadModel::RunView::RecoveryView.new(
        decision: :requires_new_implementation,
        next_action: :start_new_implementation,
        operator_action_required: false,
        summary: "a fresh implementation run is required before retrying",
        rerun_hint: "start a new implementation run and regenerate review evidence",
        package_expectation: :refresh_runtime_package,
        runtime_package_guidance: "refresh runtime package inputs before the next implementation run and rerun doctor-runtime",
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

  describe "public facade" do
    it "delegates task inspection through the task facade" do
      task = A3::Domain::Task.new(ref: "A3-v2#child", kind: :child, edit_scope: [:repo_alpha])

      expect(A3::Domain::OperatorInspectionReadModel::TaskInspection).to receive(:from_task).with(task: task, tasks: [task]).and_call_original

      described_class.from_task(task: task, tasks: [task])
    end

    it "delegates run inspection through the run facade" do
      run = A3::Domain::Run.new(
        ref: "run-1",
        task_ref: "A3-v2#child",
        phase: :implementation,
        workspace_kind: :ticket_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :ticket_workspace,
          source_type: :branch_head,
          ref: "refs/heads/a3/work/child",
          task_ref: "A3-v2#child"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "A3-v2#child",
          owner_scope: :task,
          snapshot_version: "refs/heads/a3/work/child"
        )
      )

      expect(A3::Domain::OperatorInspectionReadModel::RunInspection).to receive(:from_run).with(run, recovery: nil).and_call_original

      described_class.from_run(run, recovery: nil)
    end
  end

  describe A3::Domain::OperatorInspectionReadModel::TaskView do
    it "builds a task view with topology from task collections" do
      parent = A3::Domain::Task.new(
        ref: "A3-v2#parent",
        kind: :parent,
        edit_scope: %i[repo_alpha repo_beta],
        status: :in_review,
        child_refs: ["A3-v2#child"]
      )
      child = A3::Domain::Task.new(
        ref: "A3-v2#child",
        kind: :child,
        edit_scope: [:repo_alpha],
        verification_scope: %i[repo_alpha repo_beta],
        status: :blocked,
        current_run_ref: "run-1",
        parent_ref: "A3-v2#parent"
      )

      result = described_class.from_task(task: child, tasks: [parent, child])

      expect(result.ref).to eq("A3-v2#child")
      expect(result.kind).to eq(:child)
      expect(result.runnable_assessment.reason).to eq(:already_running)
      expect(result.runnable_assessment.blocking_task_refs).to eq(["run-1"])
      expect(result.topology.parent.ref).to eq("A3-v2#parent")
      expect(result.topology.children).to be_empty
    end

    it "marks unresolved child refs as missing relations" do
      parent = A3::Domain::Task.new(
        ref: "A3-v2#parent",
        kind: :parent,
        edit_scope: %i[repo_alpha repo_beta],
        child_refs: ["A3-v2#child"]
      )

      result = described_class.from_task(task: parent, tasks: [parent])

      expect(result.topology.children).to contain_exactly(
        have_attributes(ref: "A3-v2#child", status: :missing, current_run_ref: nil)
      )
      expect(result.runnable_assessment.reason).to eq(:parent_waiting_for_children)
      expect(result.runnable_assessment.blocking_task_refs).to eq(["A3-v2#child"])
    end
  end

  describe A3::Domain::OperatorInspectionReadModel::RunView do
    it "builds a run view with evidence summary and latest execution snapshot" do
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

      result = described_class.from_run(
        run,
        recovery: build_recovery_view(:requires_operator_action)
      )

      expect(result.ref).to eq("run-1")
      expect(result.evidence_summary.review_base).to eq("base123")
      expect(result.evidence_summary.phase_records_count).to eq(2)
      expect(result.latest_execution.phase).to eq(:review)
      expect(result.latest_execution.summary).to eq("review launch could not resolve runtime workspace")
      expect(result.latest_execution.verification_summary).to be_nil
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
        repo_scope: :repo_alpha,
        review_skill: "sample-review",
        remediation_commands: ["commands/apply-remediation"],
        merge_target: :merge_to_parent
      )
      expect(result.latest_blocked_diagnosis).to have_attributes(
        phase: :review,
        summary: "review launch could not resolve runtime workspace",
        expected_state: "runtime workspace available",
        observed_state: "repo-beta missing",
        failing_command: "codex exec --json -",
        infra_diagnostics: { "missing_path" => "/tmp/repo-beta" },
        worker_response_bundle: {
          "success" => false,
          "summary" => "review blocked",
          "failing_command" => "codex exec --json -",
          "observed_state" => "repo-beta missing"
        }
      )
      expect(result.recovery).to have_attributes(
        decision: :requires_operator_action,
        operator_action_required: true,
        summary: "blocked run requires operator action before rerun",
        rerun_hint: "diagnose blocked state and choose a fresh rerun source",
        runtime_package_guidance: "run doctor-runtime and inspect repo sources, secret delivery, and scheduler store migration before rerun"
      )
    end

    it "keeps the latest blocked diagnosis from the most recent blocked phase record" do
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
          diagnostics: {
            "worker_response_bundle" => {
              "success" => false,
              "summary" => "review blocked"
            }
          }
        )
      ).append_phase_evidence(
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
          summary: "later phase",
          diagnostics: {
            "worker_response_bundle" => {
              "success" => false,
              "summary" => "later phase bundle"
            }
          }
        )
      )

      result = described_class.from_run(
        run,
        recovery: build_recovery_view(:requires_operator_action)
      )

      expect(result.latest_execution.phase).to eq(:verification)
      expect(result.latest_blocked_diagnosis).to have_attributes(
        phase: :review,
        observed_state: "repo-beta missing",
        worker_response_bundle: {
          "success" => false,
          "summary" => "review blocked"
        }
      )
    end

    it "builds a run view without latest execution when no phase execution exists" do
      run = A3::Domain::Run.new(
        ref: "run-2",
        task_ref: "A3-v2#child",
        phase: :merge,
        workspace_kind: :runtime_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :integration_record,
          ref: "refs/heads/a3/work/child",
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
        )
      )

      result = described_class.from_run(
        run,
        recovery: nil
      )

      expect(result.evidence_summary.phase_records_count).to eq(1)
      expect(result.latest_execution).to be_nil
      expect(result.latest_blocked_diagnosis).to be_nil
      expect(result.recovery).to be_nil
      expect(result.rerun_decision).to be_nil
    end

    it "builds a run view with requires_new_implementation recovery" do
      run = A3::Domain::Run.new(
        ref: "run-4",
        task_ref: "A3-v2#child",
        phase: :review,
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

      result = described_class.from_run(
        run,
        recovery: build_recovery_view(:requires_new_implementation)
      )

      expect(result.recovery).to have_attributes(
        decision: :requires_new_implementation,
        next_action: :start_new_implementation,
        operator_action_required: false,
        summary: "a fresh implementation run is required before retrying",
        rerun_hint: "start a new implementation run and regenerate review evidence",
        package_expectation: :refresh_runtime_package,
        runtime_package_guidance: "refresh runtime package inputs before the next implementation run and rerun doctor-runtime"
      )
    end
  end

  describe A3::Domain::OperatorInspectionReadModel::SchedulerHistory do
    it "wraps cycles as an enumerable history read model" do
      cycle = A3::Domain::SchedulerCycle.new(
        executed_count: 2,
        executed_steps: [
          A3::Domain::SchedulerCycleStep.new(task_ref: "A3-v2#3030", phase: :implementation)
        ],
        idle_reached: true,
        stop_reason: :idle,
        quarantined_count: 1
      )

      history = described_class.from_cycles([cycle])

      expect(history.empty?).to eq(false)
      expect(history.map(&:cycle_number)).to eq([nil])
      expect(history.size).to eq(1)
      expect(history.first.summary).to eq("cycle= executed=2 idle=true stop_reason=idle quarantined=1")
      expect(history.first.executed_steps).to contain_exactly(
        have_attributes(
          task_ref: "A3-v2#3030",
          phase: :implementation,
          summary: "A3-v2#3030:implementation"
        )
      )
    end
  end

  describe A3::Domain::OperatorInspectionReadModel::SchedulerStateView do
    it "builds an operator-facing scheduler state summary" do
      result = described_class.from_state(
        A3::Domain::SchedulerState.new(
          paused: true,
          last_stop_reason: :max_steps,
          last_executed_count: 4
        )
      )

      expect(result.paused).to eq(true)
      expect(result.active?).to eq(false)
      expect(result.status_label).to eq(:paused)
      expect(result.last_cycle_summary).to eq("stop_reason=max_steps executed_count=4")
    end

    it "uses a no-history summary when no cycle has been recorded" do
      result = described_class.from_state(A3::Domain::SchedulerState.new)

      expect(result.status_label).to eq(:active)
      expect(result.last_cycle_summary).to eq("no cycles recorded")
    end
  end
end
