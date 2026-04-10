# frozen_string_literal: true

RSpec.describe A3::Application::ShowWatchSummary do
  subject(:use_case) do
    described_class.new(
      task_repository: task_repository,
      run_repository: run_repository,
      scheduler_state_repository: scheduler_state_repository,
      kanban_snapshots_by_ref: {
        "Portal#1" => { "title" => "Running task", "status" => "In progress" },
        "Portal#2" => { "title" => "Blocked task", "status" => "To do" },
        "Portal#3" => { "title" => "Parent task", "status" => "To do" }
      }
    )
  end

  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:run_repository) { A3::Infra::InMemoryRunRepository.new }
  let(:scheduler_state_repository) { A3::Infra::InMemorySchedulerStateRepository.new }

  it "summarizes scheduler state, task tree ordering, and kanban mismatch markers" do
    running_task = A3::Domain::Task.new(
      ref: "Portal#1",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :in_progress,
      current_run_ref: "run-1",
      parent_ref: "Portal#10"
    )
    blocked_task = A3::Domain::Task.new(
      ref: "Portal#2",
      kind: :child,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      status: :blocked,
      parent_ref: "Portal#10",
      external_task_id: 2
    )
    todo_task = A3::Domain::Task.new(
      ref: "Portal#3",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta],
      status: :todo,
      child_refs: %w[Portal#1 Portal#2]
    )
    task_repository.save(running_task)
    task_repository.save(blocked_task)
    task_repository.save(todo_task)

    run_repository.save(
      A3::Domain::Run.new(
        ref: "run-1",
        task_ref: "Portal#1",
        phase: :implementation,
        workspace_kind: :ticket_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :ticket_workspace,
          source_type: :branch_head,
          ref: "refs/heads/a3/work/Portal-1",
          task_ref: "Portal#1"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "Portal#10",
          owner_scope: :task,
          snapshot_version: "refs/heads/a3/work/Portal-1"
        )
      )
    )
    blocked_run = A3::Domain::Run.new(
      ref: "run-2",
      task_ref: "Portal#2",
      phase: :implementation,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a3/work/Portal-2",
        task_ref: "Portal#2"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_beta],
        verification_scope: [:repo_beta],
        ownership_scope: :task
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "Portal#10",
        owner_scope: :task,
        snapshot_version: "refs/heads/a3/work/Portal-2"
      ),
      terminal_outcome: :blocked
    ).append_blocked_diagnosis(
      A3::Domain::BlockedDiagnosis.new(
        task_ref: "Portal#2",
        run_ref: "run-2",
        phase: :implementation,
        outcome: :blocked,
        review_target: A3::Domain::ReviewTarget.new(
          base_commit: "base",
          head_commit: "head",
          task_ref: "Portal#2",
          phase_ref: :implementation
        ),
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :ticket_workspace,
          source_type: :branch_head,
          ref: "refs/heads/a3/work/Portal-2",
          task_ref: "Portal#2"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_beta],
          verification_scope: [:repo_beta],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "Portal#10",
          owner_scope: :task,
          snapshot_version: "refs/heads/a3/work/Portal-2"
        ),
        expected_state: "worker phase succeeds",
        observed_state: "git add failed",
        failing_command: "git add",
        diagnostic_summary: "publish failed",
        infra_diagnostics: {}
      )
    )
    run_repository.save(blocked_run)

    result = use_case.call

    expect(result.scheduler_paused).to be(false)
    expect(result.next_candidates).to eq(["Portal#3"])
    expect(result.running_entries.map(&:task_ref)).to eq(["Portal#1"])
    expect(result.running_entries.first.phase).to eq("implementation")
    expect(result.running_entries.first.internal_phase).to eq("implementation")
    expect(result.running_entries.first.state).to eq("running_command")
    expect(result.running_entries.first.detail).to eq("refs/heads/a3/work/Portal-1")
    expect(result.tasks.map(&:ref)).to eq(["Portal#3", "Portal#1", "Portal#2"])
    expect(result.tasks.find { |item| item.ref == "Portal#1" }.phase_counts).to eq("implementation" => 1)
    expect(result.tasks.find { |item| item.ref == "Portal#2" }.blocked_lines).to eq(["publish failed"])
    expect(result.tasks.find { |item| item.ref == "Portal#2" }.title).to include("[kanban=To do internal=Blocked]")
  end

  it "uses external_task_id canonical mapping and preserved run insertion order" do
    task = A3::Domain::Task.new(
      ref: "Portal#imported-7",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :blocked,
      external_task_id: 7
    )
    task_repository.save(task)

    older_run = A3::Domain::Run.new(
      ref: "run-older",
      task_ref: "Portal#imported-7",
      phase: :implementation,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a3/work/Portal-imported-7",
        task_ref: "Portal#imported-7"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :task
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "Portal#imported-7",
        owner_scope: :task,
        snapshot_version: "refs/heads/a3/work/Portal-imported-7"
      )
    )
    latest_run = A3::Domain::Run.new(
      ref: "run-newer",
      task_ref: "Portal#imported-7",
      phase: :review,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a3/work/Portal-imported-7",
        task_ref: "Portal#imported-7"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :task
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "Portal#imported-7",
        owner_scope: :task,
        snapshot_version: "refs/heads/a3/work/Portal-imported-7"
      )
    ).append_blocked_diagnosis(
      A3::Domain::BlockedDiagnosis.new(
        task_ref: "Portal#imported-7",
        run_ref: "run-newer",
        phase: :review,
        outcome: :blocked,
        review_target: A3::Domain::ReviewTarget.new(
          base_commit: "base",
          head_commit: "head",
          task_ref: "Portal#imported-7",
          phase_ref: :review
        ),
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :ticket_workspace,
          source_type: :branch_head,
          ref: "refs/heads/a3/work/Portal-imported-7",
          task_ref: "Portal#imported-7"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "Portal#imported-7",
          owner_scope: :task,
          snapshot_version: "refs/heads/a3/work/Portal-imported-7"
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
        "Portal#imported-7" => { "id" => 99, "ref" => "Portal#imported-7", "title" => "Ref-only task", "status" => "Done" }
      },
      kanban_snapshots_by_id: {
        7 => { "id" => 7, "ref" => "Portal#7", "title" => "Imported task", "status" => "To do" }
      }
    ).call

    task_entry = result.tasks.find { |item| item.ref == "Portal#imported-7" }
    expect(task_entry.title).to include("Imported task")
    expect(task_entry.title).to include("[kanban=To do internal=Blocked]")
    expect(task_entry.latest_phase).to eq("inspection")
    expect(task_entry.blocked_lines).to eq(["review blocked"])
    expect(task_entry.phase_counts).to eq("implementation" => 1, "inspection" => 1)
  end

  it "treats in-review tasks with a current run as running review work" do
    task = A3::Domain::Task.new(
      ref: "Portal#3141",
      kind: :child,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      status: :in_review,
      current_run_ref: "run-review",
      parent_ref: "Portal#3140"
    )
    task_repository.save(task)

    run_repository.save(
      A3::Domain::Run.new(
        ref: "run-review",
        task_ref: "Portal#3141",
        phase: :review,
        workspace_kind: :runtime_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :branch_head,
          ref: "refs/heads/a3/work/Portal-3141",
          task_ref: "Portal#3141"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_beta],
          verification_scope: [:repo_beta],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "Portal#3140",
          owner_scope: :task,
          snapshot_version: "refs/heads/a3/work/Portal-3141"
        )
      )
    )

    result = use_case.call

    task_entry = result.tasks.find { |item| item.ref == "Portal#3141" }
    expect(task_entry.running).to be(true)
    expect(task_entry.latest_phase).to eq("inspection")
    expect(result.running_entries.map(&:task_ref)).to eq(["Portal#3141"])
    expect(result.running_entries.first.phase).to eq("verification")
  end
end
