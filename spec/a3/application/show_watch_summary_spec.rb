# frozen_string_literal: true

RSpec.describe A3::Application::ShowWatchSummary do
  let(:inherited_parent_state_resolver) { instance_double("InheritedParentStateResolver") }
  let(:upstream_line_guard) { A3::Domain::UpstreamLineGuard.new(inherited_parent_state_resolver: inherited_parent_state_resolver) }
  let(:agent_jobs_by_task_ref) { {} }
  let(:clock) { -> { Time.utc(2026, 4, 24, 1, 0, 0) } }
  subject(:use_case) do
    described_class.new(
      task_repository: task_repository,
      run_repository: run_repository,
      scheduler_state_repository: scheduler_state_repository,
      kanban_snapshots_by_ref: {
        "Sample#1" => { "title" => "Running task", "status" => "In progress" },
        "Sample#2" => { "title" => "Blocked task", "status" => "To do" },
        "Sample#3" => { "title" => "Parent task", "status" => "To do" }
      },
      agent_jobs_by_task_ref: agent_jobs_by_task_ref,
      upstream_line_guard: upstream_line_guard,
      clock: clock
    )
  end

  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:run_repository) { A3::Infra::InMemoryRunRepository.new }
  let(:scheduler_state_repository) { A3::Infra::InMemorySchedulerStateRepository.new }

  before do
    allow(inherited_parent_state_resolver).to receive(:snapshot_for).and_return(nil)
  end

  it "summarizes scheduler state, task tree ordering, and kanban mismatch markers" do
    running_task = A3::Domain::Task.new(
      ref: "Sample#1",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :in_progress,
      current_run_ref: "run-1",
      parent_ref: "Sample#10"
    )
    blocked_task = A3::Domain::Task.new(
      ref: "Sample#2",
      kind: :child,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      status: :blocked,
      parent_ref: "Sample#10",
      external_task_id: 2
    )
    todo_task = A3::Domain::Task.new(
      ref: "Sample#3",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta],
      status: :todo,
      child_refs: %w[Sample#1 Sample#2]
    )
    task_repository.save(running_task)
    task_repository.save(blocked_task)
    task_repository.save(todo_task)

    run_repository.save(
      A3::Domain::Run.new(
        ref: "run-1",
        task_ref: "Sample#1",
        phase: :implementation,
        workspace_kind: :ticket_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :ticket_workspace,
          source_type: :branch_head,
          ref: "refs/heads/a2o/work/Sample-1",
          task_ref: "Sample#1"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "Sample#10",
          owner_scope: :task,
          snapshot_version: "refs/heads/a2o/work/Sample-1"
        )
      )
    )
    blocked_run = A3::Domain::Run.new(
      ref: "run-2",
      task_ref: "Sample#2",
      phase: :implementation,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a2o/work/Sample-2",
        task_ref: "Sample#2"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_beta],
        verification_scope: [:repo_beta],
        ownership_scope: :task
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "Sample#10",
        owner_scope: :task,
        snapshot_version: "refs/heads/a2o/work/Sample-2"
      ),
      terminal_outcome: :blocked
    ).append_blocked_diagnosis(
      A3::Domain::BlockedDiagnosis.new(
        task_ref: "Sample#2",
        run_ref: "run-2",
        phase: :implementation,
        outcome: :blocked,
        review_target: A3::Domain::ReviewTarget.new(
          base_commit: "base",
          head_commit: "head",
          task_ref: "Sample#2",
          phase_ref: :implementation
        ),
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :ticket_workspace,
          source_type: :branch_head,
          ref: "refs/heads/a2o/work/Sample-2",
          task_ref: "Sample#2"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_beta],
          verification_scope: [:repo_beta],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "Sample#10",
          owner_scope: :task,
          snapshot_version: "refs/heads/a2o/work/Sample-2"
        ),
        expected_state: "worker phase succeeds",
        observed_state: "git add failed",
        failing_command: "git add",
        diagnostic_summary: "publish failed",
        infra_diagnostics: {
          "validation_errors" => [
            "observed_state must be a string when success is false unless rework_required is true"
          ]
        }
      )
    )
    run_repository.save(blocked_run)

    result = use_case.call

    expect(result.scheduler_paused).to be(false)
    expect(result.next_candidates).to eq([])
    expect(result.running_entries.map(&:task_ref)).to eq(["Sample#1"])
    expect(result.running_entries.first.phase).to eq("implementation")
    expect(result.running_entries.first.internal_phase).to eq("implementation")
    expect(result.running_entries.first.state).to eq("running_command")
    expect(result.running_entries.first.heartbeat_age_seconds).to be_nil
    expect(result.running_entries.first.detail).to eq("refs/heads/a2o/work/Sample-1")
    expect(result.tasks.map(&:ref)).to eq(["Sample#3", "Sample#1", "Sample#2"])
    expect(result.tasks.find { |item| item.ref == "Sample#1" }.phase_counts).to eq("implementation" => 1)
    expect(result.tasks.find { |item| item.ref == "Sample#2" }.blocked_lines).to eq([
      "error_category=executor_failed",
      "remediation=executor command が agent 環境で実行可能か、必要な binary と認証、出力 JSON を確認してください。",
      "validation_error=observed_state must be a string when success is false unless rework_required is true",
      "publish failed"
    ])
    expect(result.tasks.find { |item| item.ref == "Sample#3" }.waiting).to be(true)
    expect(result.tasks.find { |item| item.ref == "Sample#3" }.blocked_lines).to include("waiting_reason=parent_waiting_for_children")
    expect(result.tasks.find { |item| item.ref == "Sample#3" }.blocked_lines).to include("waiting_on=Sample#1,Sample#2")
    expect(result.tasks.find { |item| item.ref == "Sample#2" }.title).to include("[kanban=To do internal=Blocked]")
  end

  it "uses agent job heartbeat data for running entries when available" do
    task = A3::Domain::Task.new(
      ref: "Sample#1",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :in_progress,
      current_run_ref: "run-1"
    )
    task_repository.save(task)
    run_repository.save(
      A3::Domain::Run.new(
        ref: "run-1",
        task_ref: "Sample#1",
        phase: :implementation,
        workspace_kind: :ticket_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :ticket_workspace,
          source_type: :branch_head,
          ref: "refs/heads/a2o/work/Sample-1",
          task_ref: "Sample#1"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "Sample#1",
          owner_scope: :task,
          snapshot_version: "refs/heads/a2o/work/Sample-1"
        )
      )
    )

    agent_jobs_by_task_ref["Sample#1"] = {
      "task_ref" => "Sample#1",
      "heartbeat_at" => "2026-04-24T00:59:30Z",
      "updated_at_epoch_ms" => 1
    }

    result = use_case.call

    expect(result.running_entries.first.heartbeat_age_seconds).to eq(30)
  end

  it "sorts top-level parent groups by blocker dependencies" do
    blocked_parent = A3::Domain::Task.new(
      ref: "Sample#10",
      kind: :parent,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :todo,
      child_refs: %w[Sample#11],
      blocking_task_refs: %w[Sample#9]
    )
    blocked_child = A3::Domain::Task.new(
      ref: "Sample#11",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :todo,
      parent_ref: blocked_parent.ref
    )
    blocker_parent = A3::Domain::Task.new(
      ref: "Sample#9",
      kind: :parent,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      status: :todo,
      child_refs: %w[Sample#12]
    )
    blocker_child = A3::Domain::Task.new(
      ref: "Sample#12",
      kind: :child,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      status: :todo,
      parent_ref: blocker_parent.ref
    )
    [blocked_parent, blocked_child, blocker_parent, blocker_child].each { |task| task_repository.save(task) }

    result = use_case.call

    expect(result.tasks.map(&:ref)).to eq(%w[Sample#9 Sample#12 Sample#10 Sample#11])
  end

  it "sorts children within a parent by blocker dependencies and numeric ticket tie-breaks" do
    parent = A3::Domain::Task.new(
      ref: "Sample#100",
      kind: :parent,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :todo,
      child_refs: %w[Sample#10 Sample#9 Sample#11]
    )
    later_child = A3::Domain::Task.new(
      ref: "Sample#11",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :todo,
      parent_ref: parent.ref,
      blocking_task_refs: %w[Sample#9 Sample#10]
    )
    child_ten = A3::Domain::Task.new(
      ref: "Sample#10",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :todo,
      parent_ref: parent.ref
    )
    child_nine = A3::Domain::Task.new(
      ref: "Sample#9",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :todo,
      parent_ref: parent.ref
    )
    [parent, later_child, child_ten, child_nine].each { |task| task_repository.save(task) }

    result = use_case.call

    expect(result.tasks.map(&:ref)).to eq(%w[Sample#100 Sample#9 Sample#10 Sample#11])
  end

  it "does not let cross-parent child blockers reorder a parent's children" do
    parent_a = A3::Domain::Task.new(
      ref: "Sample#200",
      kind: :parent,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :todo,
      child_refs: %w[Sample#201]
    )
    child_a = A3::Domain::Task.new(
      ref: "Sample#201",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :todo,
      parent_ref: parent_a.ref,
      blocking_task_refs: %w[Sample#301]
    )
    parent_b = A3::Domain::Task.new(
      ref: "Sample#300",
      kind: :parent,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      status: :todo,
      child_refs: %w[Sample#301]
    )
    child_b = A3::Domain::Task.new(
      ref: "Sample#301",
      kind: :child,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      status: :todo,
      parent_ref: parent_b.ref
    )
    [parent_a, child_a, parent_b, child_b].each { |task| task_repository.save(task) }

    result = use_case.call

    expect(result.tasks.map(&:ref)).to eq(%w[Sample#200 Sample#201 Sample#300 Sample#301])
  end

  it "keeps displaying tasks with cyclic blockers using numeric fallback order" do
    task_ten = A3::Domain::Task.new(
      ref: "Sample#10",
      kind: :single,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :todo,
      blocking_task_refs: %w[Sample#9]
    )
    task_nine = A3::Domain::Task.new(
      ref: "Sample#9",
      kind: :single,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :todo,
      blocking_task_refs: %w[Sample#10]
    )
    [task_ten, task_nine].each { |task| task_repository.save(task) }

    result = use_case.call

    expect(result.tasks.map(&:ref)).to eq(%w[Sample#9 Sample#10])
  end

  it "uses kanban current tasks as the watch-summary set while overlaying runtime state" do
    stale_runtime_task = A3::Domain::Task.new(
      ref: "Sample#stale",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :blocked
    )
    current_done_task = A3::Domain::Task.new(
      ref: "Sample#done",
      kind: :single,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :done,
      external_task_id: 10
    )
    current_running_task = A3::Domain::Task.new(
      ref: "Sample#live",
      kind: :child,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      status: :in_progress,
      current_run_ref: "run-live",
      external_task_id: 11
    )
    task_repository.save(stale_runtime_task)
    task_repository.save(current_running_task)

    run_repository.save(
      A3::Domain::Run.new(
        ref: "run-live",
        task_ref: "Sample#live",
        phase: :implementation,
        workspace_kind: :ticket_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :ticket_workspace,
          source_type: :branch_head,
          ref: "refs/heads/a2o/work/Sample-live",
          task_ref: "Sample#live"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_beta],
          verification_scope: [:repo_beta],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "Sample#live",
          owner_scope: :task,
          snapshot_version: "refs/heads/a2o/work/Sample-live"
        )
      )
    )

    result = described_class.new(
      task_repository: task_repository,
      run_repository: run_repository,
      scheduler_state_repository: scheduler_state_repository,
      kanban_tasks: [current_done_task, current_running_task],
      kanban_snapshots_by_ref: {
        "Sample#done" => { "id" => 10, "ref" => "Sample#done", "title" => "Current done", "status" => "Done" },
        "Sample#live" => { "id" => 11, "ref" => "Sample#live", "title" => "Current running", "status" => "In progress" }
      },
      kanban_snapshots_by_id: {
        10 => { "id" => 10, "ref" => "Sample#done", "title" => "Current done", "status" => "Done" },
        11 => { "id" => 11, "ref" => "Sample#live", "title" => "Current running", "status" => "In progress" }
      },
      upstream_line_guard: upstream_line_guard
    ).call

    expect(result.tasks.map(&:ref)).to eq(["Sample#done", "Sample#live"])
    expect(result.tasks.find { |item| item.ref == "Sample#done" }.done).to be(true)
    expect(result.tasks.find { |item| item.ref == "Sample#live" }.running).to be(true)
    expect(result.running_entries.map(&:task_ref)).to eq(["Sample#live"])
  end

  it "surfaces the latest implementation review disposition in task detail lines" do
    task = A3::Domain::Task.new(
      ref: "Sample#reviewed",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :verifying,
      parent_ref: "Sample#parent"
    )
    source_descriptor = A3::Domain::SourceDescriptor.new(
      workspace_kind: :ticket_workspace,
      source_type: :branch_head,
      ref: "refs/heads/a2o/work/Sample-reviewed",
      task_ref: task.ref
    )
    scope_snapshot = A3::Domain::ScopeSnapshot.new(
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      ownership_scope: :task
    )
    task_repository.save(task)
    run_repository.save(
      A3::Domain::Run.new(
        ref: "run-reviewed",
        task_ref: task.ref,
        phase: :implementation,
        workspace_kind: :ticket_workspace,
        source_descriptor: source_descriptor,
        scope_snapshot: scope_snapshot,
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: task.ref,
          owner_scope: :task,
          snapshot_version: "refs/heads/a2o/work/Sample-reviewed"
        )
      ).append_phase_evidence(
        phase: :implementation,
        source_descriptor: source_descriptor,
        scope_snapshot: scope_snapshot,
        execution_record: A3::Domain::PhaseExecutionRecord.new(
          summary: "implementation completed",
          review_disposition: {
            "kind" => "completed",
            "repo_scope" => "repo_alpha",
            "summary" => "self-review found no findings",
            "description" => "reviewed diff and tests",
            "finding_key" => "implementation-review-clean"
          }
        )
      ).complete(outcome: :completed)
    )
    run_repository.save(
      A3::Domain::Run.new(
        ref: "run-verification",
        task_ref: task.ref,
        phase: :verification,
        workspace_kind: :runtime_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :detached_commit,
          ref: "refs/heads/a2o/work/Sample-reviewed",
          task_ref: task.ref
        ),
        scope_snapshot: scope_snapshot,
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: task.ref,
          owner_scope: :task,
          snapshot_version: "refs/heads/a2o/work/Sample-reviewed"
        )
      ).append_phase_evidence(
        phase: :verification,
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :detached_commit,
          ref: "refs/heads/a2o/work/Sample-reviewed",
          task_ref: task.ref
        ),
        scope_snapshot: scope_snapshot,
        execution_record: A3::Domain::PhaseExecutionRecord.new(
          summary: "verification completed",
          review_disposition: {
            "kind" => "completed",
            "repo_scope" => "repo_alpha",
            "summary" => "verification metadata should not override implementation review",
            "description" => "future non-review phase metadata",
            "finding_key" => "verification-metadata"
          }
        )
      )
    )
    run_repository.save(
      A3::Domain::Run.new(
        ref: "run-merge",
        task_ref: task.ref,
        phase: :merge,
        workspace_kind: :runtime_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :detached_commit,
          ref: "refs/heads/a2o/work/Sample-reviewed",
          task_ref: task.ref
        ),
        scope_snapshot: scope_snapshot,
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: task.ref,
          owner_scope: :task,
          snapshot_version: "refs/heads/a2o/work/Sample-reviewed"
        )
      )
    )

    result = use_case.call

    detail_lines = result.tasks.find { |item| item.ref == "Sample#reviewed" }.blocked_lines
    expect(detail_lines).to include("review=completed repo_scope=repo_alpha finding_key=implementation-review-clean")
    expect(detail_lines).to include("review_summary=self-review found no findings")
  end

  it "marks only the selected highest-priority runnable task as next" do
    low_priority = A3::Domain::Task.new(
      ref: "Sample#100",
      kind: :single,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :todo,
      priority: 2
    )
    high_priority = A3::Domain::Task.new(
      ref: "Sample#200",
      kind: :single,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      status: :todo,
      priority: 4
    )
    task_repository.save(low_priority)
    task_repository.save(high_priority)

    result = use_case.call

    expect(result.next_candidates).to eq(["Sample#200"])
    expect(result.tasks.find { |item| item.ref == "Sample#100" }.next_candidate).to be(false)
    expect(result.tasks.find { |item| item.ref == "Sample#200" }.next_candidate).to be(true)
  end

  it "marks the highest-priority child inside the highest-priority parent group as next" do
    parent_a = A3::Domain::Task.new(
      ref: "Sample#5000",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta],
      status: :todo,
      child_refs: %w[Sample#5001 Sample#5002],
      priority: 4
    )
    child_a1 = A3::Domain::Task.new(
      ref: "Sample#5001",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :todo,
      parent_ref: parent_a.ref,
      priority: 1
    )
    child_a2 = A3::Domain::Task.new(
      ref: "Sample#5002",
      kind: :child,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      status: :todo,
      parent_ref: parent_a.ref,
      priority: 3
    )
    parent_b = A3::Domain::Task.new(
      ref: "Sample#5010",
      kind: :parent,
      edit_scope: %i[repo_gamma repo_delta],
      verification_scope: %i[repo_gamma repo_delta],
      status: :todo,
      child_refs: %w[Sample#5011],
      priority: 2
    )
    child_b1 = A3::Domain::Task.new(
      ref: "Sample#5011",
      kind: :child,
      edit_scope: [:repo_gamma],
      verification_scope: [:repo_gamma],
      status: :todo,
      parent_ref: parent_b.ref,
      priority: 9
    )
    [parent_a, child_a1, child_a2, parent_b, child_b1].each { |task| task_repository.save(task) }

    result = use_case.call

    expect(result.next_candidates).to eq(["Sample#5002"])
    expect(result.tasks.find { |item| item.ref == "Sample#5002" }.next_candidate).to be(true)
    expect(result.tasks.find { |item| item.ref == "Sample#5011" }.next_candidate).to be(false)
  end

  it "shows a child waiting on inherited parent blockers" do
    parent_blocker = A3::Domain::Task.new(
      ref: "Sample#6000",
      kind: :single,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :todo
    )
    parent = A3::Domain::Task.new(
      ref: "Sample#6001",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta],
      status: :todo,
      child_refs: %w[Sample#6002],
      blocking_task_refs: [parent_blocker.ref]
    )
    child = A3::Domain::Task.new(
      ref: "Sample#6002",
      kind: :child,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      status: :todo,
      parent_ref: parent.ref
    )
    [parent_blocker, parent, child].each { |task| task_repository.save(task) }

    result = use_case.call
    child_entry = result.tasks.find { |item| item.ref == child.ref }

    expect(child_entry.waiting).to be(true)
    expect(child_entry.blocked).to be(false)
    expect(child_entry.blocked_lines).to include("waiting_reason=blocked_by_tasks", "waiting_on=Sample#6000")
  end

  it "uses external_task_id canonical mapping and preserved run insertion order" do
    task = A3::Domain::Task.new(
      ref: "Sample#imported-7",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :blocked,
      external_task_id: 7
    )
    task_repository.save(task)

    older_run = A3::Domain::Run.new(
      ref: "run-older",
      task_ref: "Sample#imported-7",
      phase: :implementation,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a2o/work/Sample-imported-7",
        task_ref: "Sample#imported-7"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :task
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "Sample#imported-7",
        owner_scope: :task,
        snapshot_version: "refs/heads/a2o/work/Sample-imported-7"
      )
    )
    latest_run = A3::Domain::Run.new(
      ref: "run-newer",
      task_ref: "Sample#imported-7",
      phase: :review,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a2o/work/Sample-imported-7",
        task_ref: "Sample#imported-7"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :task
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "Sample#imported-7",
        owner_scope: :task,
        snapshot_version: "refs/heads/a2o/work/Sample-imported-7"
      )
    ).append_blocked_diagnosis(
      A3::Domain::BlockedDiagnosis.new(
        task_ref: "Sample#imported-7",
        run_ref: "run-newer",
        phase: :review,
        outcome: :blocked,
        review_target: A3::Domain::ReviewTarget.new(
          base_commit: "base",
          head_commit: "head",
          task_ref: "Sample#imported-7",
          phase_ref: :review
        ),
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :ticket_workspace,
          source_type: :branch_head,
          ref: "refs/heads/a2o/work/Sample-imported-7",
          task_ref: "Sample#imported-7"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "Sample#imported-7",
          owner_scope: :task,
          snapshot_version: "refs/heads/a2o/work/Sample-imported-7"
        ),
        expected_state: "review succeeds",
        observed_state: "review failed",
        failing_command: "bundle exec rspec",
        diagnostic_summary: "review blocked",
        infra_diagnostics: {}
      )
    )
    run_repository.save(older_run)
    run_repository.save(latest_run)

    result = described_class.new(
      task_repository: task_repository,
      run_repository: run_repository,
      scheduler_state_repository: scheduler_state_repository,
      kanban_snapshots_by_ref: {
        "Sample#imported-7" => { "id" => 99, "ref" => "Sample#imported-7", "title" => "Ref-only task", "status" => "Done" }
      },
      kanban_snapshots_by_id: {
        7 => { "id" => 7, "ref" => "Sample#7", "title" => "Imported task", "status" => "To do" }
      }
    ).call

    task_entry = result.tasks.find { |item| item.ref == "Sample#imported-7" }
    expect(task_entry.title).to include("Imported task")
    expect(task_entry.title).to include("[kanban=To do internal=Blocked]")
    expect(task_entry.latest_phase).to eq("review")
      expect(task_entry.blocked_lines).to eq([
        "error_category=executor_failed",
        "remediation=executor command が agent 環境で実行可能か、必要な binary と認証、出力 JSON を確認してください。",
        "review blocked"
      ])
    expect(task_entry.phase_counts).to eq("implementation" => 1, "review" => 1)
  end

  it "does not infer latest phase for run-less terminal tasks" do
    task_repository.save(
      A3::Domain::Task.new(
        ref: "Sample#done",
        kind: :single,
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        status: :done
      )
    )

    result = use_case.call

    task_entry = result.tasks.find { |item| item.ref == "Sample#done" }
    expect(task_entry.latest_phase).to be_nil
  end

  it "shows merge recovery verification source details" do
    task = A3::Domain::Task.new(
      ref: "Sample#245",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :verifying,
      parent_ref: "Sample#201",
      verification_source_ref: "refs/heads/a2o/parent/Sample-201"
    )
    task_repository.save(task)

    result = use_case.call

    task_entry = result.tasks.find { |item| item.ref == "Sample#245" }
    expect(task_entry.latest_phase).to eq("inspection")
    expect(task_entry.blocked_lines).to include("merge_recovery verification_source_ref=refs/heads/a2o/parent/Sample-201")
  end

  it "treats in-review tasks with a current run as running review work" do
    task = A3::Domain::Task.new(
      ref: "Sample#3141",
      kind: :child,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      status: :in_review,
      current_run_ref: "run-review",
      parent_ref: "Sample#3140"
    )
    task_repository.save(task)

    run_repository.save(
      A3::Domain::Run.new(
        ref: "run-review",
        task_ref: "Sample#3141",
        phase: :review,
        workspace_kind: :runtime_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :branch_head,
          ref: "refs/heads/a2o/work/Sample-3141",
          task_ref: "Sample#3141"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_beta],
          verification_scope: [:repo_beta],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "Sample#3140",
          owner_scope: :task,
          snapshot_version: "refs/heads/a2o/work/Sample-3141"
        )
      )
    )

    result = use_case.call

    task_entry = result.tasks.find { |item| item.ref == "Sample#3141" }
    expect(task_entry.running).to be(true)
    expect(task_entry.latest_phase).to eq("review")
    expect(result.running_entries.map(&:task_ref)).to eq(["Sample#3141"])
    expect(result.running_entries.first.phase).to eq("review")
  end

  it "marks todo children as waiting when a sibling under the same parent is blocked" do
    parent_ref = "refs/heads/a2o/parent/Sample-10"
    blocked_task = A3::Domain::Task.new(
      ref: "Sample#20",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :blocked,
      parent_ref: "Sample#10"
    )
    waiting_task = A3::Domain::Task.new(
      ref: "Sample#21",
      kind: :child,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      status: :todo,
      parent_ref: "Sample#10"
    )
    parent_task = A3::Domain::Task.new(
      ref: "Sample#10",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta],
      status: :todo,
      child_refs: %w[Sample#20 Sample#21]
    )
    task_repository.save(parent_task)
    task_repository.save(blocked_task)
    task_repository.save(waiting_task)
    allow(inherited_parent_state_resolver).to receive(:snapshot_for).with(
      task: waiting_task,
      phase: :implementation
    ).and_return(
      Struct.new(:ref, :heads_by_slot) do
        def fingerprint
          heads_by_slot.sort_by { |slot, _head| slot.to_s }.map { |slot, head| "#{slot}=#{head}" }.join("|")
        end
      end.new(parent_ref, { "repo_alpha" => "parent-head-alpha-1", "repo_beta" => "parent-head-beta-1" })
    )
    run_repository.save(
      A3::Domain::Run.new(
        ref: "run-20",
        task_ref: "Sample#20",
        phase: :verification,
        workspace_kind: :runtime_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :integration_record,
          ref: parent_ref,
          task_ref: "Sample#20"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "Sample#10",
          owner_scope: :task,
          snapshot_version: "refs/heads/a2o/work/Sample-20"
        ),
        terminal_outcome: :blocked
      ).append_blocked_diagnosis(
        A3::Domain::BlockedDiagnosis.new(
          task_ref: "Sample#20",
          run_ref: "run-20",
          phase: :verification,
          outcome: :blocked,
          review_target: A3::Domain::ReviewTarget.new(
            base_commit: "base",
            head_commit: "head",
            task_ref: "Sample#20",
            phase_ref: :verification
          ),
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :runtime_workspace,
            source_type: :integration_record,
            ref: parent_ref,
            task_ref: "Sample#20"
          ),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(
            edit_scope: [:repo_alpha],
            verification_scope: [:repo_alpha],
            ownership_scope: :task
          ),
          artifact_owner: A3::Domain::ArtifactOwner.new(
            owner_ref: "Sample#10",
            owner_scope: :task,
            snapshot_version: "refs/heads/a2o/work/Sample-20"
          ),
          expected_state: "verification succeeds",
          observed_state: "lint failed on inherited parent line",
          failing_command: "commands/verify-all",
          diagnostic_summary: "verification failed",
          infra_diagnostics: {}
        ),
        execution_record: A3::Domain::PhaseExecutionRecord.new(
          summary: "verification failed",
          diagnostics: {
            "inherited_parent_ref" => parent_ref,
            "inherited_parent_state_fingerprint" => "repo_alpha=parent-head-alpha-1|repo_beta=parent-head-beta-1"
          }
        )
      )
    )

    result = use_case.call
    task_entry = result.tasks.find { |item| item.ref == "Sample#21" }

    expect(result.next_candidates).to eq([])
    expect(task_entry.waiting).to be(true)
    expect(task_entry.next_candidate).to be(false)
    expect(task_entry.blocked_lines).to include("waiting_reason=upstream_unhealthy")
    expect(task_entry.blocked_lines).to include("waiting_on=Sample#20")
  end
end
