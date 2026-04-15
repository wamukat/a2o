# frozen_string_literal: true

RSpec.describe A3::Application::PlanNextPhase do
  subject(:use_case) { described_class.new }

  let(:artifact_owner) do
    A3::Domain::ArtifactOwner.new(
      owner_ref: "A3-v2#3025",
      owner_scope: :task,
      snapshot_version: "snap-1"
    )
  end

  it "moves a child task from implementation to verification" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha]
    )

    run = A3::Domain::Run.new(
      ref: "run-1",
      task_ref: task.ref,
      phase: :implementation,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a3/work/3025",
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

    result = use_case.call(task: task, run: run, outcome: :completed)

    expect(result.next_phase).to eq(:verification)
  end

  it "moves a parent task from review to verification" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3022",
      kind: :parent,
      edit_scope: [:repo_beta, :repo_alpha]
    )

    run = A3::Domain::Run.new(
      ref: "run-2",
      task_ref: task.ref,
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a3/parent/3022",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_beta, :repo_alpha],
        verification_scope: [:repo_beta, :repo_alpha],
        ownership_scope: :parent
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :parent,
        snapshot_version: "snap-1"
      )
    )

    result = use_case.call(task: task, run: run, outcome: :completed)

    expect(result.next_phase).to eq(:verification)
  end

  it "moves a parent task from verification to merge" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3022",
      kind: :parent,
      edit_scope: [:repo_beta, :repo_alpha],
      status: :verifying
    )

    run = A3::Domain::Run.new(
      ref: "run-2b",
      task_ref: task.ref,
      phase: :verification,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a3/parent/3022",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_beta, :repo_alpha],
        verification_scope: [:repo_beta, :repo_alpha],
        ownership_scope: :parent
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :parent,
        snapshot_version: "snap-1"
      )
    )

    result = use_case.call(task: task, run: run, outcome: :completed)

    expect(result.next_phase).to eq(:merge)
  end

  it "marks a child merge as terminal done" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha]
    )

    run = A3::Domain::Run.new(
      ref: "run-3",
      task_ref: task.ref,
      phase: :merge,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a3/parent/3022",
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

    result = use_case.call(task: task, run: run, outcome: :completed)

    expect(result.next_phase).to be_nil
    expect(result.terminal_status).to eq(:done)
  end

  it "keeps blocked runs terminal" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha]
    )

    run = A3::Domain::Run.new(
      ref: "run-4",
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

    result = use_case.call(task: task, run: run, outcome: :blocked)

    expect(result.next_phase).to be_nil
    expect(result.terminal_status).to eq(:blocked)
  end

  it "routes review findings into rework without advancing the phase" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :in_review
    )

    run = A3::Domain::Run.new(
      ref: "run-4b",
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

    result = use_case.call(task: task, run: run, outcome: :rework)

    expect(result.next_phase).to be_nil
    expect(result.terminal_status).to eq(:in_progress)
  end

  it "routes merge recovery completion back to verification" do
    task = A3::Domain::Task.new(
      ref: "Portal#1",
      kind: :single,
      edit_scope: [:repo_alpha],
      status: :merging
    )
    run = A3::Domain::Run.new(
      ref: "run-merge",
      task_ref: task.ref,
      phase: :merge,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.runtime_integration_record(task_ref: task.ref, ref: "refs/heads/main"),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: [:repo_alpha], verification_scope: [:repo_alpha], ownership_scope: :task),
      artifact_owner: A3::Domain::ArtifactOwner.new(owner_ref: task.ref, owner_scope: :task, snapshot_version: "refs/heads/main")
    )

    result = use_case.call(task: task, run: run, outcome: :verification_required)

    expect(result.next_phase).to eq(:verification)
    expect(result.terminal_status).to be_nil
  end

  it "keeps retryable runs on the current status without advancing phase" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :in_progress
    )

    run = A3::Domain::Run.new(
      ref: "run-5",
      task_ref: task.ref,
      phase: :implementation,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a3/work/3025",
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

    result = use_case.call(task: task, run: run, outcome: :retryable)

    expect(result.next_phase).to be_nil
    expect(result.terminal_status).to eq(:in_progress)
  end

  it "keeps terminal noop runs on the current status without advancing phase" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :merging
    )

    run = A3::Domain::Run.new(
      ref: "run-6",
      task_ref: task.ref,
      phase: :merge,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a3/parent/3022",
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

    result = use_case.call(task: task, run: run, outcome: :terminal_noop)

    expect(result.next_phase).to be_nil
    expect(result.terminal_status).to eq(:merging)
  end
end
