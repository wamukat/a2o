# frozen_string_literal: true

RSpec.describe A3::Application::SyncExternalTasks do
  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:external_task_source) { instance_double("ExternalTaskSource") }

  subject(:use_case) do
    described_class.new(
      task_repository: task_repository,
      external_task_source: external_task_source
    )
  end

  it "is a no-op when no external task source is configured" do
    local_task = A3::Domain::Task.new(
      ref: "Sample#3046",
      kind: :single,
      edit_scope: [:repo_beta],
      status: :todo
    )
    task_repository.save(local_task)
    use_case = described_class.new(
      task_repository: task_repository,
      external_task_source: A3::Infra::NullExternalTaskSource.new
    )

    result = use_case.call

    expect(task_repository.fetch("Sample#3046")).to eq(local_task)
    expect(result.imported_task_refs).to eq([])
    expect(result.pruned_task_refs).to eq([])
  end

  it "saves imported external tasks into the repository" do
    task = A3::Domain::Task.new(
      ref: "Sample#3046",
      kind: :child,
      edit_scope: [:repo_beta],
      status: :todo,
      external_task_id: 3046
    )
    allow(external_task_source).to receive(:load).and_return([task])

    result = use_case.call

    expect(task_repository.fetch("Sample#3046")).to eq(task)
    expect(result.imported_task_refs).to eq(["Sample#3046"])
    expect(result.pruned_task_refs).to eq([])
  end

  it "preserves active local execution while refreshing external identity and topology" do
    local_task = A3::Domain::Task.new(
      ref: "Sample#3046",
      kind: :child,
      edit_scope: [:repo_beta],
      status: :in_progress,
      current_run_ref: "run-1",
      external_task_id: 3046
    )
    imported_task = A3::Domain::Task.new(
      ref: "Sample#3046",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta],
      status: :todo,
      child_refs: ["Sample#3047"],
      external_task_id: 4100
    )
    task_repository.save(local_task)
    allow(external_task_source).to receive(:load).and_return([imported_task])

    result = use_case.call

    reconciled = task_repository.fetch("Sample#3046")
    expect(reconciled.status).to eq(:in_progress)
    expect(reconciled.current_run_ref).to eq("run-1")
    expect(reconciled.kind).to eq(:parent)
    expect(reconciled.child_refs).to eq(["Sample#3047"])
    expect(reconciled.external_task_id).to eq(4100)
    expect(result.preserved_active_task_refs).to eq(["Sample#3046"])
  end

  it "preserves active parent-child topology when the imported task still reports hidden unresolved children" do
    local_task = A3::Domain::Task.new(
      ref: "Sample#3046",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta],
      status: :in_progress,
      current_run_ref: "run-1",
      child_refs: %w[Sample#3047 Sample#3048],
      external_task_id: 3046
    )
    imported_task = A3::Domain::Task.new(
      ref: "Sample#3046",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta],
      status: :todo,
      child_refs: %w[Sample#3047 Sample#3048],
      external_task_id: 4100
    )
    task_repository.save(local_task)
    allow(external_task_source).to receive(:load).and_return([imported_task])

    result = use_case.call

    reconciled = task_repository.fetch("Sample#3046")
    expect(reconciled.status).to eq(:in_progress)
    expect(reconciled.current_run_ref).to eq("run-1")
    expect(reconciled.kind).to eq(:parent)
    expect(reconciled.child_refs).to eq(%w[Sample#3047 Sample#3048])
    expect(reconciled.external_task_id).to eq(4100)
    expect(result.preserved_active_task_refs).to eq(["Sample#3046"])
  end

  it "prunes non-terminal non-active tasks that are no longer present in Kanban" do
    stale_task = A3::Domain::Task.new(
      ref: "Sample#3046",
      kind: :child,
      edit_scope: [:repo_beta],
      status: :todo,
      external_task_id: 3046
    )
    done_task = A3::Domain::Task.new(
      ref: "Sample#3047",
      kind: :child,
      edit_scope: [:repo_beta],
      status: :done,
      external_task_id: 3047
    )
    task_repository.save(stale_task)
    task_repository.save(done_task)
    allow(external_task_source).to receive(:load).and_return([])

    result = use_case.call

    expect { task_repository.fetch("Sample#3046") }.to raise_error(A3::Domain::RecordNotFound)
    expect(task_repository.fetch("Sample#3047")).to eq(done_task)
    expect(result.pruned_task_refs).to eq(["Sample#3046"])
  end

  it "preserves a non-active task when Kanban still has it outside the filtered source status" do
    progressed_task = A3::Domain::Task.new(
      ref: "Sample#3046",
      kind: :single,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      status: :verifying,
      external_task_id: 3046
    )
    refreshed_task = A3::Domain::Task.new(
      ref: "Sample#3046",
      kind: :single,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      status: :verifying,
      external_task_id: 3046
    )
    task_repository.save(progressed_task)
    allow(external_task_source).to receive(:load).and_return([])
    allow(external_task_source).to receive(:fetch_by_external_task_id).with(3046).and_return(refreshed_task)

    result = use_case.call

    expect(task_repository.fetch("Sample#3046")).to eq(refreshed_task)
    expect(result.pruned_task_refs).to eq([])
  end

  it "preserves existing parent topology during single-task refresh outside the filtered source status" do
    progressed_task = A3::Domain::Task.new(
      ref: "Sample#3046",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta],
      status: :in_review,
      child_refs: ["Sample#3047"],
      external_task_id: 3046
    )
    refreshed_task = A3::Domain::Task.new(
      ref: "Sample#3046",
      kind: :single,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta],
      status: :in_review,
      external_task_id: 3046
    )
    task_repository.save(progressed_task)
    allow(external_task_source).to receive(:load).and_return([])
    allow(external_task_source).to receive(:fetch_by_external_task_id).with(3046).and_return(refreshed_task)

    result = use_case.call

    preserved = task_repository.fetch("Sample#3046")
    expect(preserved.kind).to eq(:parent)
    expect(preserved.child_refs).to eq(["Sample#3047"])
    expect(preserved.status).to eq(:in_review)
    expect(result.pruned_task_refs).to eq([])
  end

  it "canonicalizes imported child in_review to verifying during refresh" do
    local_task = A3::Domain::Task.new(
      ref: "Sample#3046",
      kind: :child,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      status: :todo,
      parent_ref: "Sample#3040",
      external_task_id: 3046
    )
    refreshed_task = A3::Domain::Task.new(
      ref: "Sample#3046",
      kind: :child,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      status: :verifying,
      parent_ref: "Sample#3040",
      external_task_id: 3046
    )
    task_repository.save(local_task)
    allow(external_task_source).to receive(:load).and_return([])
    allow(external_task_source).to receive(:fetch_by_external_task_id).with(3046).and_return(refreshed_task)

    use_case.call

    expect(task_repository.fetch("Sample#3046").status).to eq(:verifying)
  end

  it "refreshes a blocked task from Kanban when the blocked label has been cleared" do
    blocked_task = A3::Domain::Task.new(
      ref: "Sample#3046",
      kind: :single,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      status: :blocked,
      external_task_id: 3046
    )
    refreshed_task = A3::Domain::Task.new(
      ref: "Sample#3046",
      kind: :single,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      status: :todo,
      external_task_id: 3046
    )
    task_repository.save(blocked_task)
    allow(external_task_source).to receive(:load).and_return([])
    allow(external_task_source).to receive(:fetch_by_external_task_id).with(3046).and_return(refreshed_task)

    result = use_case.call

    expect(task_repository.fetch("Sample#3046")).to eq(refreshed_task)
    expect(result.pruned_task_refs).to eq([])
  end

end
