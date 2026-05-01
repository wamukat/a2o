# frozen_string_literal: true

RSpec.describe A3::Application::PlanRunnableTaskBatch do
  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:run_repository) { A3::Infra::InMemoryRunRepository.new }
  let(:claim_repository) do
    counter = 0
    A3::Infra::InMemorySchedulerTaskClaimRepository.new(
      claim_ref_generator: -> { counter += 1; "claim-#{counter}" }
    )
  end
  let(:sync_external_tasks) { instance_double(A3::Application::SyncExternalTasks, call: nil) }

  subject(:use_case) do
    described_class.new(
      task_repository: task_repository,
      run_repository: run_repository,
      task_claim_repository: claim_repository,
      max_parallel_tasks: 2,
      sync_external_tasks: sync_external_tasks
    )
  end

  it "selects independent runnable tasks in scheduler order" do
    save_task(ref: "A2O#2", priority: 1)
    save_task(ref: "A2O#1", priority: 4)
    save_task(ref: "A2O#3", priority: 2)

    result = use_case.call

    expect(result.candidates.map { |candidate| candidate.task.ref }).to eq(%w[A2O#1 A2O#3])
    expect(result.candidates.map(&:phase)).to eq(%i[implementation implementation])
    expect(result.active_slot_count).to eq(0)
    expect(result.available_slot_count).to eq(2)
    expect(result).not_to be_busy
    expect(sync_external_tasks).to have_received(:call)
  end

  it "does not select sibling children in the same batch" do
    parent = save_task(
      ref: "A2O#10",
      kind: :parent,
      child_refs: %w[A2O#11 A2O#12],
      priority: 5
    )
    save_task(ref: "A2O#11", kind: :child, parent_ref: parent.ref, priority: 4)
    save_task(ref: "A2O#12", kind: :child, parent_ref: parent.ref, priority: 3)
    save_task(ref: "A2O#20", priority: 1)

    result = use_case.call

    expect(result.candidates.map { |candidate| candidate.task.ref }).to eq(%w[A2O#11 A2O#20])
    conflict = result.skipped_conflicts.find { |skipped| skipped.task_ref == "A2O#12" }
    expect(conflict.reason).to eq(:in_batch)
    expect(conflict.conflict_key).to eq("parent-group:A2O#10")
    expect(conflict.holder_ref).to eq("A2O#11")
  end

  it "does not select a parent task when an active child claim holds the parent group" do
    parent = save_task(
      ref: "A2O#30",
      kind: :parent,
      status: :todo,
      child_refs: %w[A2O#31]
    )
    save_task(ref: "A2O#31", kind: :child, parent_ref: parent.ref, status: :done)
    claim_repository.claim_task(
      task_ref: "A2O#31",
      phase: :implementation,
      parent_group_key: "parent-group:A2O#30",
      claimed_by: "scheduler-1",
      claimed_at: "2026-04-30T00:00:00Z"
    )

    result = use_case.call

    expect(result.candidates).to be_empty
    expect(result).to be_waiting
    expect(result.skipped_conflicts.first.conflict_key).to eq("parent-group:A2O#30")
    expect(result.skipped_conflicts.first.reason).to eq(:active_claim)
  end

  it "does not select a child task when an active parent claim holds the parent group" do
    parent = save_task(
      ref: "A2O#35",
      kind: :parent,
      status: :todo,
      child_refs: %w[A2O#36]
    )
    save_task(ref: "A2O#36", kind: :child, parent_ref: parent.ref, status: :todo)
    claim_repository.claim_task(
      task_ref: parent.ref,
      phase: :review,
      parent_group_key: "parent-group:A2O#35",
      claimed_by: "scheduler-1",
      claimed_at: "2026-04-30T00:00:00Z"
    )

    result = use_case.call

    expect(result.candidates).to be_empty
    expect(result).to be_waiting
    conflict = result.skipped_conflicts.find { |skipped| skipped.task_ref == "A2O#36" }
    expect(conflict.conflict_key).to eq("parent-group:A2O#35")
    expect(conflict.reason).to eq(:active_claim)
  end

  it "does not select sibling tasks when an active run holds the parent group" do
    parent = save_task(
      ref: "A2O#60",
      kind: :parent,
      status: :todo,
      child_refs: %w[A2O#61 A2O#62]
    )
    save_task(ref: "A2O#61", kind: :child, parent_ref: parent.ref, status: :in_progress)
    save_task(ref: "A2O#62", kind: :child, parent_ref: parent.ref, status: :todo)
    run_repository.save(instance_double(A3::Domain::Run, ref: "run-61", task_ref: "A2O#61", terminal?: false))

    result = use_case.call

    expect(result.candidates).to be_empty
    expect(result).to be_waiting
    expect(result.active_slot_count).to eq(1)
    conflict = result.skipped_conflicts.find { |skipped| skipped.task_ref == "A2O#62" }
    expect(conflict.conflict_key).to eq("parent-group:A2O#60")
    expect(conflict.reason).to eq(:active_run)
  end

  it "reports busy when all configured slots are already occupied" do
    save_task(ref: "A2O#40", priority: 2)
    claim_repository.claim_task(
      task_ref: "A2O#41",
      phase: :implementation,
      parent_group_key: "single:A2O#41",
      claimed_by: "scheduler-1",
      claimed_at: "2026-04-30T00:00:00Z"
    )
    claim_repository.claim_task(
      task_ref: "A2O#42",
      phase: :implementation,
      parent_group_key: "single:A2O#42",
      claimed_by: "scheduler-1",
      claimed_at: "2026-04-30T00:00:01Z"
    )

    result = use_case.call

    expect(result.candidates).to be_empty
    expect(result.available_slot_count).to eq(0)
    expect(result).to be_busy
    expect(result).not_to be_idle
  end

  it "returns idle when there are no runnable candidates and slots are available" do
    save_task(ref: "A2O#50", status: :done)

    result = use_case.call

    expect(result.candidates).to be_empty
    expect(result.skipped_conflicts).to be_empty
    expect(result).to be_idle
  end

  def save_task(ref:, kind: :single, status: :todo, parent_ref: nil, child_refs: [], priority: 0)
    task = A3::Domain::Task.new(
      ref: ref,
      kind: kind,
      edit_scope: [:repo_alpha],
      status: status,
      parent_ref: parent_ref,
      child_refs: child_refs,
      priority: priority
    )
    task_repository.save(task)
    task
  end
end
