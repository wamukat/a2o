# frozen_string_literal: true

RSpec.describe A3::Application::PlanNextRunnableTask do
  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:sync_external_tasks) { instance_double(A3::Application::SyncExternalTasks, call: nil) }

  subject(:use_case) { described_class.new(task_repository: task_repository, sync_external_tasks: sync_external_tasks) }

  it "selects the next todo task before review and merge stages after reconciling external state" do
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#3024",
        kind: :single,
        edit_scope: [:repo_beta],
        status: :in_review
      )
    )
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#3023",
        kind: :single,
        edit_scope: [:repo_alpha],
        status: :todo
      )
    )

    result = use_case.call

    expect(result.task&.ref).to eq("A3-v2#3023")
    expect(result.phase).to eq(:implementation)
    expect(result.selected_assessment.reason).to eq(:runnable)
    expect(result.assessments.map(&:task_ref)).to eq(%w[A3-v2#3023 A3-v2#3024])
    expect(sync_external_tasks).to have_received(:call)
  end

  it "continues scheduling an active task after reconciling external state" do
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#3049",
        kind: :single,
        edit_scope: [:repo_beta],
        status: :verifying
      )
    )

    result = use_case.call

    expect(result.task&.ref).to eq("A3-v2#3049")
    expect(result.phase).to eq(:verification)
    expect(sync_external_tasks).to have_received(:call)
  end

  it "serializes sibling child tasks under the same parent" do
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#3020",
        kind: :child,
        edit_scope: [:repo_alpha],
        status: :in_progress,
        current_run_ref: "run-1",
        parent_ref: "A3-v2#3019"
      )
    )
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#3021",
        kind: :child,
        edit_scope: [:repo_beta],
        status: :todo,
        parent_ref: "A3-v2#3019"
      )
    )

    result = use_case.call

    expect(result.task).to be_nil
    sibling_assessment = result.assessments.find { |assessment| assessment.task_ref == "A3-v2#3021" }
    expect(sibling_assessment.reason).to eq(:sibling_running)
    expect(sibling_assessment.blocking_task_refs).to eq(["A3-v2#3020"])
  end

  it "does not schedule a parent until all children are done" do
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#3020",
        kind: :child,
        edit_scope: [:repo_alpha],
        status: :done,
        parent_ref: "A3-v2#3019"
      )
    )
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#3021",
        kind: :child,
        edit_scope: [:repo_beta],
        status: :verifying,
        parent_ref: "A3-v2#3019"
      )
    )
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#3019",
        kind: :parent,
        edit_scope: [:repo_alpha, :repo_beta],
        status: :todo,
        child_refs: %w[A3-v2#3020 A3-v2#3021]
      )
    )

    result = use_case.call

    expect(result.task&.ref).to eq("A3-v2#3021")
    expect(result.phase).to eq(:verification)
    expect(result.assessments.find { |assessment| assessment.task_ref == "A3-v2#3019" }.reason).to eq(:parent_waiting_for_children)
  end

  it "schedules the parent review when all children are done" do
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#3020",
        kind: :child,
        edit_scope: [:repo_alpha],
        status: :done,
        parent_ref: "A3-v2#3019"
      )
    )
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#3021",
        kind: :child,
        edit_scope: [:repo_beta],
        status: :done,
        parent_ref: "A3-v2#3019"
      )
    )
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#3019",
        kind: :parent,
        edit_scope: [:repo_alpha, :repo_beta],
        status: :todo,
        child_refs: %w[A3-v2#3020 A3-v2#3021]
      )
    )

    result = use_case.call

    expect(result.task&.ref).to eq("A3-v2#3019")
    expect(result.phase).to eq(:review)
    expect(result.selected_assessment.reason).to eq(:runnable)
  end

  it "schedules parent verification when the parent is verifying" do
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#3020",
        kind: :child,
        edit_scope: [:repo_alpha],
        status: :done,
        parent_ref: "A3-v2#3019"
      )
    )
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#3021",
        kind: :child,
        edit_scope: [:repo_beta],
        status: :done,
        parent_ref: "A3-v2#3019"
      )
    )
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#3019",
        kind: :parent,
        edit_scope: [:repo_alpha, :repo_beta],
        verification_scope: [:repo_alpha, :repo_beta],
        status: :verifying,
        child_refs: %w[A3-v2#3020 A3-v2#3021]
      )
    )

    result = use_case.call

    expect(result.task&.ref).to eq("A3-v2#3019")
    expect(result.phase).to eq(:verification)
    expect(result.selected_assessment.reason).to eq(:runnable)
  end

  it "schedules parent merge when the parent is merging" do
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#3020",
        kind: :child,
        edit_scope: [:repo_alpha],
        status: :done,
        parent_ref: "A3-v2#3019"
      )
    )
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#3021",
        kind: :child,
        edit_scope: [:repo_beta],
        status: :done,
        parent_ref: "A3-v2#3019"
      )
    )
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#3019",
        kind: :parent,
        edit_scope: [:repo_alpha, :repo_beta],
        verification_scope: [:repo_alpha, :repo_beta],
        status: :merging,
        child_refs: %w[A3-v2#3020 A3-v2#3021]
      )
    )

    result = use_case.call

    expect(result.task&.ref).to eq("A3-v2#3019")
    expect(result.phase).to eq(:merge)
    expect(result.selected_assessment.reason).to eq(:runnable)
  end

  it "explains tasks that cannot be run because they are already active" do
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#3031",
        kind: :child,
        edit_scope: [:repo_beta],
        status: :in_progress,
        current_run_ref: "run-1",
        parent_ref: "A3-v2#3022"
      )
    )

    result = use_case.call

    expect(result.task).to be_nil
    expect(result.assessments.first.reason).to eq(:already_running)
  end
end
