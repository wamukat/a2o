# frozen_string_literal: true

RSpec.describe A3::Application::PhaseExecutionOrchestrator do
  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:run_repository) { A3::Infra::InMemoryRunRepository.new }
  let(:integration_ref_readiness_checker) do
    instance_double(
      A3::Infra::IntegrationRefReadinessChecker,
      check: A3::Infra::IntegrationRefReadinessChecker::Result.new(ready: true, missing_slots: [], ref: "refs/heads/a2o/parent/A3-v2-3022")
    )
  end
  let(:handle_parent_review_disposition) { nil }
  let(:register_completed_run) do
    A3::Application::RegisterCompletedRun.new(
      task_repository: task_repository,
      run_repository: run_repository,
      plan_next_phase: A3::Application::PlanNextPhase.new,
      integration_ref_readiness_checker: integration_ref_readiness_checker,
      handle_parent_review_disposition: handle_parent_review_disposition
    )
  end
  let(:prepare_workspace) { instance_double(A3::Application::PrepareWorkspace) }

  subject(:orchestrator) do
    described_class.new(
      run_repository: run_repository,
      register_completed_run: register_completed_run,
      prepare_workspace: prepare_workspace
    )
  end

  let(:task) do
    A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: %i[repo_alpha repo_beta],
      status: :in_progress,
      current_run_ref: "run-1",
      parent_ref: "A3-v2#3022"
    )
  end

  let(:run) do
    A3::Domain::Run.new(
      ref: "run-1",
      task_ref: task.ref,
      phase: :implementation,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a2o/work/3025",
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
        owner_ref: "A3-v2#3022",
        owner_scope: :task,
        snapshot_version: "head456"
      )
    )
  end

  let(:runtime) do
    A3::Domain::PhaseRuntimeConfig.new(
      task_kind: :child,
      repo_scope: :repo_alpha,
      phase: :implementation,
      implementation_skill: "skills/implementation/base.md",
      review_skill: "skills/review/base.md",
      verification_commands: ["commands/verify-all"],
      remediation_commands: ["commands/apply-remediation"],
      workspace_hook: "hooks/prepare-runtime.sh",
      merge_target: :merge_to_parent,
      merge_policy: :ff_only
    )
  end

  let(:prepared_workspace) do
    A3::Domain::PreparedWorkspace.new(
      workspace_kind: :ticket_workspace,
      root_path: "/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace",
      source_descriptor: run.source_descriptor,
      slot_paths: { repo_alpha: "/tmp/work/repo-alpha" }
    )
  end

  before do
    task_repository.save(task)
    run_repository.save(run)
  end

  it "prepares workspace from run/runtime context" do
    allow(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_workspace)
    )

    result = orchestrator.prepare(task: task, run: run, runtime: runtime)

    expect(result.workspace).to eq(prepared_workspace)
    expect(prepare_workspace).to have_received(:call).with(
      task: task,
      phase: :implementation,
      source_descriptor: run.source_descriptor,
      scope_snapshot: run.scope_snapshot,
      artifact_owner: run.artifact_owner,
      bootstrap_marker: "hooks/prepare-runtime.sh"
    )
  end

  it "persists blocked execution evidence with runtime snapshot and completes the run" do
    execution = A3::Application::ExecutionResult.new(
      success: false,
      summary: "worker failed",
      failing_command: "worker_gateway",
      observed_state: "exit 1",
      diagnostics: { "stderr" => "boom" }
    )
    blocked_diagnosis = A3::Domain::BlockedDiagnosis.new(
      task_ref: task.ref,
      run_ref: run.ref,
      phase: :implementation,
      outcome: :blocked,
      review_target: run.evidence.review_target,
      source_descriptor: run.source_descriptor,
      scope_snapshot: run.scope_snapshot,
      artifact_owner: run.artifact_owner,
      expected_state: "worker phase succeeds",
      observed_state: "exit 1",
      failing_command: "worker_gateway",
      diagnostic_summary: "worker failed",
      infra_diagnostics: { "stderr" => "boom" }
    )

    result = orchestrator.persist_and_complete(
      task_ref: task.ref,
      run_ref: run.ref,
      task: task,
      run: run,
      runtime: runtime,
      execution: execution,
      blocked_diagnosis: blocked_diagnosis
    )

    expect(result.run.phase_records.last.execution_record).to have_attributes(
      summary: "worker failed",
      failing_command: "worker_gateway",
      observed_state: "exit 1",
      diagnostics: { "stderr" => "boom" }
    )
    expect(result.run.phase_records.last.execution_record.runtime_snapshot).to have_attributes(
      phase: :implementation,
      remediation_commands: ["commands/apply-remediation"]
    )
    expect(result.task.status).to eq(:blocked)
    expect(result.run.terminal_outcome).to eq(:blocked)
  end

  it "routes review findings back to implementation instead of leaving the task blocked" do
    review_task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: %i[repo_alpha repo_beta],
      status: :in_review,
      current_run_ref: "run-review-1",
      parent_ref: "A3-v2#3022"
    )
    review_run = A3::Domain::Run.new(
      ref: "run-review-1",
      task_ref: review_task.ref,
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "head456",
        task_ref: review_task.ref
      ),
      scope_snapshot: run.scope_snapshot,
      review_target: run.evidence.review_target,
      artifact_owner: run.artifact_owner
    )
    execution = A3::Application::ExecutionResult.new(
      success: false,
      summary: "review found runner-layout gap",
      failing_command: "review_worker",
      observed_state: "review_findings",
      response_bundle: { "rework_required" => true }
    )
    blocked_diagnosis = A3::Domain::BlockedDiagnosis.new(
      task_ref: review_task.ref,
      run_ref: review_run.ref,
      phase: :review,
      outcome: :blocked,
      review_target: review_run.evidence.review_target,
      source_descriptor: review_run.source_descriptor,
      scope_snapshot: review_run.scope_snapshot,
      artifact_owner: review_run.artifact_owner,
      expected_state: "review passes cleanly",
      observed_state: "review_findings",
      failing_command: "review_worker",
      diagnostic_summary: "review found runner-layout gap",
      infra_diagnostics: {}
    )

    task_repository.save(review_task)
    run_repository.save(review_run)

    result = orchestrator.persist_and_complete(
      task_ref: review_task.ref,
      run_ref: review_run.ref,
      task: review_task,
      run: review_run,
      runtime: runtime,
      execution: execution,
      blocked_diagnosis: blocked_diagnosis
    )

    expect(result.task.status).to eq(:in_progress)
    expect(result.run.terminal_outcome).to eq(:rework)
  end

  it "stops a task in needs_clarification without recording blocked diagnostics" do
    clarification = {
      "question" => "Which API contract should win?",
      "context" => "The requested behavior conflicts with the public permission model.",
      "options" => ["Change the public contract", "Keep the existing contract"],
      "recommended_option" => "Keep the existing contract",
      "impact" => "A2O will not schedule this task again until the request is answered."
    }
    execution = A3::Application::ExecutionResult.new(
      success: false,
      summary: "requirement conflict",
      response_bundle: {
        "success" => false,
        "summary" => "requirement conflict",
        "rework_required" => false,
        "clarification_request" => clarification
      }
    )
    blocked_diagnosis = A3::Domain::BlockedDiagnosis.new(
      task_ref: task.ref,
      run_ref: run.ref,
      phase: :implementation,
      outcome: :blocked,
      review_target: run.evidence.review_target,
      source_descriptor: run.source_descriptor,
      scope_snapshot: run.scope_snapshot,
      artifact_owner: run.artifact_owner,
      expected_state: "worker phase succeeds",
      observed_state: "ambiguous requirement",
      failing_command: "worker_gateway",
      diagnostic_summary: "requirement conflict",
      infra_diagnostics: {}
    )

    result = orchestrator.persist_and_complete(
      task_ref: task.ref,
      run_ref: run.ref,
      task: task,
      run: run,
      runtime: runtime,
      execution: execution,
      blocked_diagnosis: blocked_diagnosis
    )

    expect(result.task.status).to eq(:needs_clarification)
    expect(result.run.terminal_outcome).to eq(:needs_clarification)
    expect(result.run.phase_records.last.blocked_diagnosis).to be_nil
    expect(result.run.phase_records.last.execution_record.clarification_request).to eq(clarification)
  end

  it "routes parent review follow-up disposition before generic success completion" do
    handler_result = A3::Application::HandleParentReviewDisposition::Result.new(
      terminal_status: :todo,
      terminal_outcome: :follow_up_child,
      follow_up_child_refs: ["Sample#3200"],
      comment_lines: ["follow_up_children: Sample#3200"]
    )
    handler = instance_double(A3::Application::HandleParentReviewDisposition, call: handler_result)
    overridden_register_completed_run = A3::Application::RegisterCompletedRun.new(
      task_repository: task_repository,
      run_repository: run_repository,
      plan_next_phase: A3::Application::PlanNextPhase.new,
      integration_ref_readiness_checker: integration_ref_readiness_checker,
      handle_parent_review_disposition: handler
    )
    overridden_orchestrator = described_class.new(
      run_repository: run_repository,
      register_completed_run: overridden_register_completed_run,
      prepare_workspace: prepare_workspace
    )
    parent_task = A3::Domain::Task.new(
      ref: "Sample#3140",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta],
      status: :in_review,
      current_run_ref: "run-parent-review-1"
    )
    parent_run = A3::Domain::Run.new(
      ref: "run-parent-review-1",
      task_ref: parent_task.ref,
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/parent/Sample-3140",
        task_ref: parent_task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: %i[repo_alpha repo_beta],
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :parent
      ),
      review_target: run.evidence.review_target,
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: parent_task.ref,
        owner_scope: :parent,
        snapshot_version: "snap-1"
      )
    )
    execution = A3::Application::ExecutionResult.new(
      success: true,
      summary: "repo_beta follow-up required",
      failing_command: nil,
      observed_state: "review_findings",
      response_bundle: {
        "rework_required" => false,
        "review_disposition" => {
          "kind" => "follow_up_child",
          "slot_scopes" => ["repo_beta"],
          "summary" => "repo_beta follow-up required",
          "description" => "legacy malformed params should redirect",
          "finding_key" => "parent-review-1"
        }
      }
    )

    task_repository.save(parent_task)
    run_repository.save(parent_run)

    result = overridden_orchestrator.persist_and_complete(
      task_ref: parent_task.ref,
      run_ref: parent_run.ref,
      task: parent_task,
      run: parent_run,
      runtime: runtime,
      execution: execution
    )

    expect(result.run.terminal_outcome).to eq(:follow_up_child)
    expect(handler).to have_received(:call)
  end

  it "fails closed when parent review success carries a blocked disposition" do
    parent_task = A3::Domain::Task.new(
      ref: "Sample#3141",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta],
      status: :in_review,
      current_run_ref: "run-parent-review-blocked"
    )
    parent_run = A3::Domain::Run.new(
      ref: "run-parent-review-blocked",
      task_ref: parent_task.ref,
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/parent/Sample-3141",
        task_ref: parent_task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: %i[repo_alpha repo_beta],
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :parent
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: parent_task.ref,
        owner_scope: :parent,
        snapshot_version: "snap-1"
      )
    )
    execution = A3::Application::ExecutionResult.new(
      success: true,
      summary: "parent review blocked",
      response_bundle: {
        "rework_required" => false,
        "review_disposition" => {
          "kind" => "blocked",
          "slot_scopes" => ["unresolved"],
          "summary" => "cannot route follow-up",
          "description" => "No configured repo scope can handle this finding.",
          "finding_key" => "parent-review-blocked"
        }
      }
    )

    outcome = orchestrator.send(:completion_outcome_for, task: parent_task, run: parent_run, execution: execution)

    expect(outcome).to eq(:blocked)
  end
end
