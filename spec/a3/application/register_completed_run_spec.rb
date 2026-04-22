# frozen_string_literal: true

RSpec.describe A3::Application::RegisterCompletedRun do
  subject(:use_case) do
    described_class.new(
      task_repository: task_repository,
      run_repository: run_repository,
      plan_next_phase: plan_next_phase,
      publish_external_task_status: status_publisher,
      publish_external_task_activity: activity_publisher,
      integration_ref_readiness_checker: integration_ref_readiness_checker,
      handle_parent_review_disposition: handle_parent_review_disposition
    )
  end

  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:run_repository) { A3::Infra::InMemoryRunRepository.new }
  let(:plan_next_phase) { A3::Application::PlanNextPhase.new }
  let(:status_publisher) { instance_double(A3::Infra::NullExternalTaskStatusPublisher, publish: nil) }
  let(:activity_publisher) { instance_double("ExternalTaskActivityPublisher", publish: nil) }
  let(:handle_parent_review_disposition) { nil }
  let(:integration_ref_readiness_checker) { instance_double(A3::Infra::IntegrationRefReadinessChecker, check: readiness_result) }
  let(:readiness_result) do
    A3::Infra::IntegrationRefReadinessChecker::Result.new(
      ready: true,
      missing_slots: [],
      ref: "refs/heads/a2o/parent/A3-v2-3022"
    )
  end

  let(:artifact_owner) do
    A3::Domain::ArtifactOwner.new(
      owner_ref: "A3-v2#3025",
      owner_scope: :task,
      snapshot_version: "snap-1"
    )
  end

  let(:run) do
    A3::Domain::Run.new(
      ref: "run-1",
      task_ref: "A3-v2#3025",
      phase: :implementation,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a2o/work/3025",
        task_ref: "A3-v2#3025"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: "A3-v2#3025",
        phase_ref: :review
      ),
      artifact_owner: artifact_owner
    )
  end

  let(:implementation_execution_record) do
    A3::Domain::PhaseExecutionRecord.new(
      summary: "implemented redirect handling and verified targeted tests",
      diagnostics: {}
    )
  end

  it "moves a completed implementation run to verifying" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :in_progress,
      current_run_ref: "run-1",
      external_task_id: 3025
    )
    task_repository.save(task)
    run_repository.save(
      run.append_phase_evidence(
        phase: run.phase,
        source_descriptor: run.source_descriptor,
        scope_snapshot: run.scope_snapshot,
        execution_record: implementation_execution_record
      )
    )

    expect(status_publisher).to receive(:publish).with(task_ref: task.ref, external_task_id: 3025, status: :verifying, task_kind: :child)
    expect(activity_publisher).to receive(:publish).with(
      task_ref: task.ref,
      external_task_id: 3025,
      body: a_string_matching(/A2O 実行完了: implementation.*要約: implemented redirect handling and verified targeted tests/m)
    )
    result = use_case.call(task_ref: task.ref, run_ref: run.ref, outcome: :completed)

    expect(result.task.status).to eq(:verifying)
    expect(result.task.current_run_ref).to be_nil
    expect(result.run.terminal_outcome).to eq(:completed)
  end

  it "moves a blocked review run to blocked" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :in_review,
      current_run_ref: "run-1",
      external_task_id: 3025
    )
    task_repository.save(task)
    review_run = A3::Domain::Run.new(
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
        verification_scope: [:repo_alpha],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
        phase_ref: :review
      ),
      artifact_owner: artifact_owner
    )
    blocked_diagnosis = A3::Domain::BlockedDiagnosis.new(
      task_ref: task.ref,
      run_ref: review_run.ref,
      phase: :review,
      outcome: :blocked,
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
        phase_ref: :review
      ),
      source_descriptor: review_run.source_descriptor,
      scope_snapshot: review_run.scope_snapshot,
      artifact_owner: artifact_owner,
      expected_state: "review succeeds",
      observed_state: "findings remain",
      failing_command: "review_worker",
      diagnostic_summary: "review found runner-layout gap in repo-alpha",
      infra_diagnostics: {
        "inherited_parent_ref" => "refs/heads/a2o/parent/A3-v2-3022",
        "inherited_parent_state_fingerprint" => "repo_alpha=parent-head-alpha-1|repo_beta=parent-head-beta-1"
      }
    )
    run_repository.save(review_run.append_blocked_diagnosis(blocked_diagnosis))

    expect(status_publisher).to receive(:publish).with(task_ref: task.ref, external_task_id: 3025, status: :blocked, task_kind: :child)
    expect(activity_publisher).to receive(:publish).with(
      task_ref: task.ref,
      external_task_id: 3025,
      body: a_string_matching(/A2O 実行完了: review.*エラー分類: executor_failed.*主要失敗要約: review found runner-layout gap in repo-alpha.*主要失敗コマンド: review_worker.*継承元親状態: refs\/heads\/a2o\/parent\/A3-v2-3022.*次の対応: executor command.*観測状態: findings remain/m)
    )
    result = use_case.call(task_ref: task.ref, run_ref: review_run.ref, outcome: :blocked)

    expect(result.task.status).to eq(:blocked)
    expect(result.task.current_run_ref).to be_nil
    expect(result.run.terminal_outcome).to eq(:blocked)
  end

  it "moves a completed merge run to done" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :merging,
      current_run_ref: "run-9",
      external_task_id: 3025
    )
    task_repository.save(task)
    merge_run = A3::Domain::Run.new(
      ref: "run-9",
      task_ref: task.ref,
      phase: :merge,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/parent/3022",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
        phase_ref: :review
      ),
      artifact_owner: artifact_owner
    )
    run_repository.save(merge_run)

    expect(status_publisher).to receive(:publish).with(task_ref: task.ref, external_task_id: 3025, status: :done, task_kind: :child)
    expect(activity_publisher).to receive(:publish).with(task_ref: task.ref, external_task_id: 3025, body: /A2O 実行完了: merge/)
    result = use_case.call(task_ref: task.ref, run_ref: merge_run.ref, outcome: :completed)

    expect(result.task.status).to eq(:done)
    expect(result.run.terminal_outcome).to eq(:completed)
  end

  it "requires verification against the published merge target after merge recovery" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :merging,
      current_run_ref: "run-9",
      external_task_id: 3025
    )
    task_repository.save(task)
    merge_run = A3::Domain::Run.new(
      ref: "run-9",
      task_ref: task.ref,
      phase: :merge,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/parent/3022",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :task
      ),
      artifact_owner: artifact_owner
    )
    run_repository.save(merge_run)
    execution = A3::Application::ExecutionResult.new(
      success: true,
      summary: "merge recovery published",
      diagnostics: {
        "merge_recovery" => {
          "status" => "recovered",
          "target_ref" => "refs/heads/a2o/parent/3022",
          "publish_before_head" => "abc123",
          "publish_after_head" => "def456"
        }
      },
      response_bundle: {
        "merge_recovery_verification_required" => true,
        "merge_recovery_verification_source_ref" => "refs/heads/a2o/parent/3022"
      }
    )

    expect(status_publisher).to receive(:publish).with(task_ref: task.ref, external_task_id: 3025, status: :verifying, task_kind: :child)
    expect(activity_publisher).to receive(:publish).with(
      task_ref: task.ref,
      external_task_id: 3025,
      body: a_string_matching(/merge_recovery: recovered.*merge_recovery_target: refs\/heads\/a2o\/parent\/3022.*merge_recovery_publish: abc123\.\.def456/m)
    )
    result = use_case.call(task_ref: task.ref, run_ref: merge_run.ref, outcome: :verification_required, execution: execution)

    expect(result.task.status).to eq(:verifying)
    expect(result.task.verification_source_ref).to eq("refs/heads/a2o/parent/3022")
    expect(result.run.terminal_outcome).to eq(:verification_required)
  end

  it "blocks a completed child merge when the parent integration ref is missing in its edit scope" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :merging,
      current_run_ref: "run-9",
      parent_ref: "A3-v2#3022",
      external_task_id: 3025
    )
    task_repository.save(task)
    merge_run = A3::Domain::Run.new(
      ref: "run-9",
      task_ref: task.ref,
      phase: :merge,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/work/3025",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
        phase_ref: :merge
      ),
      artifact_owner: artifact_owner
    )
    run_repository.save(merge_run)
    allow(integration_ref_readiness_checker).to receive(:check).and_return(
      A3::Infra::IntegrationRefReadinessChecker::Result.new(
        ready: false,
        missing_slots: [:repo_alpha],
        ref: "refs/heads/a2o/parent/A3-v2-3022"
      )
    )

    expect(status_publisher).to receive(:publish).with(task_ref: task.ref, external_task_id: 3025, status: :blocked, task_kind: :child)
    expect(activity_publisher).to receive(:publish).with(
      task_ref: task.ref,
      external_task_id: 3025,
      body: a_string_matching(/主要失敗要約: missing integration ref refs\/heads\/a2o\/parent\/A3-v2-3022 for slots repo_alpha/)
    )

    result = use_case.call(task_ref: task.ref, run_ref: merge_run.ref, outcome: :completed)

    expect(result.task.status).to eq(:blocked)
    expect(result.run.terminal_outcome).to eq(:blocked)
  end

  it "keeps a retryable implementation run in progress" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :in_progress,
      current_run_ref: "run-1",
      external_task_id: 3025
    )
    task_repository.save(task)
    run_repository.save(run)

    expect(status_publisher).to receive(:publish).with(task_ref: task.ref, external_task_id: 3025, status: :in_progress, task_kind: :child)
    expect(activity_publisher).to receive(:publish).with(task_ref: task.ref, external_task_id: 3025, body: /A2O 実行完了: implementation/)
    result = use_case.call(task_ref: task.ref, run_ref: run.ref, outcome: :retryable)

    expect(result.task.status).to eq(:in_progress)
    expect(result.task.current_run_ref).to be_nil
    expect(result.run.terminal_outcome).to eq(:retryable)
  end

  it "preserves recovery verification source on retryable verification runs" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :verifying,
      current_run_ref: "run-verification-1",
      external_task_id: 3025,
      verification_source_ref: "refs/heads/a2o/parent/3022"
    )
    verification_run = A3::Domain::Run.new(
      ref: "run-verification-1",
      task_ref: task.ref,
      phase: :verification,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.runtime(task_ref: task.ref, ref: task.verification_source_ref, source_type: :branch_head),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: [:repo_alpha], verification_scope: [:repo_alpha], ownership_scope: :task),
      artifact_owner: artifact_owner
    )
    task_repository.save(task)
    run_repository.save(verification_run)

    expect(status_publisher).to receive(:publish).with(task_ref: task.ref, external_task_id: 3025, status: :verifying, task_kind: :child)
    expect(activity_publisher).to receive(:publish).with(task_ref: task.ref, external_task_id: 3025, body: /A2O 実行完了: verification/)
    result = use_case.call(task_ref: task.ref, run_ref: verification_run.ref, outcome: :retryable)

    expect(result.task.status).to eq(:verifying)
    expect(result.task.current_run_ref).to be_nil
    expect(result.task.verification_source_ref).to eq("refs/heads/a2o/parent/3022")
    expect(result.run.terminal_outcome).to eq(:retryable)
  end

  it "routes parent review follow-up findings into new child work without returning the parent to implementation" do
    parent_task = A3::Domain::Task.new(
      ref: "Sample#3140",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      status: :in_review,
      current_run_ref: "run-parent-review-1",
      child_refs: %w[Sample#3138 Sample#3141],
      external_task_id: 3140
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
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: parent_task.ref,
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: parent_task.ref,
        owner_scope: :parent,
        snapshot_version: "snap-1"
      )
    )
    disposition = A3::Domain::ReviewDisposition.new(
      kind: :follow_up_child,
      repo_scope: :repo_beta,
      summary: "add redirect fallback follow-up",
      description: "legacy malformed params should redirect to /points",
      finding_key: "sample-3140-repo-beta-1"
    )
    execution = A3::Application::ExecutionResult.new(
      success: false,
      summary: disposition.summary,
      failing_command: nil,
      observed_state: "review_findings",
      response_bundle: {
        "rework_required" => false,
        "review_disposition" => {
          "kind" => "follow_up_child",
          "repo_scope" => "repo_beta",
          "summary" => disposition.summary,
          "description" => disposition.description,
          "finding_key" => disposition.finding_key
        }
      }
    )
    handler_result = A3::Application::HandleParentReviewDisposition::Result.new(
      terminal_status: :todo,
      terminal_outcome: :follow_up_child,
      follow_up_child_refs: ["Sample#3200"],
      follow_up_child_fingerprints: ["Sample#3140|run-parent-review-1|repo_beta|sample-3140-repo-beta-1"],
      comment_lines: ["follow_up_children: Sample#3200"]
    )
    handler = instance_double(A3::Application::HandleParentReviewDisposition, call: handler_result)
    task_repository.save(parent_task)
    run_repository.save(
      parent_run.append_phase_evidence(
        phase: parent_run.phase,
        source_descriptor: parent_run.source_descriptor,
        scope_snapshot: parent_run.scope_snapshot,
        execution_record: A3::Domain::PhaseExecutionRecord.from_execution_result(execution)
      )
    )

    overridden_use_case = described_class.new(
      task_repository: task_repository,
      run_repository: run_repository,
      plan_next_phase: plan_next_phase,
      publish_external_task_status: status_publisher,
      publish_external_task_activity: activity_publisher,
      integration_ref_readiness_checker: integration_ref_readiness_checker,
      handle_parent_review_disposition: handler
    )

    expect(status_publisher).to receive(:publish).with(task_ref: parent_task.ref, external_task_id: 3140, status: :todo, task_kind: :parent)
    expect(activity_publisher).to receive(:publish).with(
      task_ref: parent_task.ref,
      external_task_id: 3140,
      body: a_string_matching(/follow_up_children: Sample#3200/)
    )

    result = overridden_use_case.call(task_ref: parent_task.ref, run_ref: parent_run.ref, outcome: :follow_up_child, execution: execution)

    expect(result.task.status).to eq(:todo)
    expect(result.task.current_run_ref).to be_nil
    expect(result.run.terminal_outcome).to eq(:follow_up_child)
    expect(result.run.phase_records.last.execution_record.follow_up_child_fingerprints).to eq(
      ["Sample#3140|run-parent-review-1|repo_beta|sample-3140-repo-beta-1"]
    )
    expect(handler).to have_received(:call).with(
      task: parent_task,
      run: have_attributes(ref: parent_run.ref, phase: :review, task_ref: parent_task.ref),
      disposition: have_attributes(
        kind: :follow_up_child,
        repo_scope: :repo_beta,
        summary: disposition.summary,
        description: disposition.description,
        finding_key: disposition.finding_key
      )
    )
  end

  it "fails closed when parent review re-enters through rework without a canonical disposition handler" do
    parent_task = A3::Domain::Task.new(
      ref: "Sample#3140",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      status: :in_review,
      current_run_ref: "run-parent-review-1",
      child_refs: %w[Sample#3138 Sample#3141],
      external_task_id: 3140
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
    task_repository.save(parent_task)
    run_repository.save(parent_run)

    expect(status_publisher).to receive(:publish).with(task_ref: parent_task.ref, external_task_id: 3140, status: :blocked, task_kind: :parent)

    result = use_case.call(task_ref: parent_task.ref, run_ref: parent_run.ref, outcome: :rework)

    expect(result.task.status).to eq(:blocked)
    expect(result.run.terminal_outcome).to eq(:blocked)
    expect(result.run.phase_records.last.blocked_diagnosis.diagnostic_summary).to eq("parent review disposition handler is missing")
  end

  it "preserves the latest execution diagnostics when parent review is blocked by disposition handling" do
    parent_task = A3::Domain::Task.new(
      ref: "Sample#3140",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      status: :in_review,
      current_run_ref: "run-parent-review-2",
      child_refs: %w[Sample#3138 Sample#3141],
      external_task_id: 3140
    )
    execution_record = A3::Domain::PhaseExecutionRecord.new(
      summary: "stdin worker returned no final result",
      failing_command: "codex exec --json",
      observed_state: "missing_worker_result",
      diagnostics: { "stdout" => "partial", "stderr" => "none" }
    )
    parent_run = A3::Domain::Run.new(
      ref: "run-parent-review-2",
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
    ).append_phase_evidence(
      phase: :review,
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
      execution_record: execution_record
    )
    task_repository.save(parent_task)
    run_repository.save(parent_run)

    result = use_case.call(task_ref: parent_task.ref, run_ref: parent_run.ref, outcome: :rework)

    latest = result.run.phase_records.last.execution_record
    expect(latest.summary).to eq("stdin worker returned no final result")
    expect(latest.diagnostics).to eq("stdout" => "partial", "stderr" => "none")
  end
end
