# frozen_string_literal: true

require "a3/domain/runnable_task_assessment"

RSpec.describe A3::Domain::RunnableTaskAssessment do
  let(:tasks) do
    [
      A3::Domain::Task.new(
        ref: "A3-v2#3020",
        kind: :child,
        edit_scope: [:repo_alpha],
        status: :in_progress,
        current_run_ref: "run-1",
        parent_ref: "A3-v2#3019"
      ),
      A3::Domain::Task.new(
        ref: "A3-v2#3021",
        kind: :child,
        edit_scope: [:repo_beta],
        status: :todo,
        parent_ref: "A3-v2#3019"
      ),
      A3::Domain::Task.new(
        ref: "A3-v2#3019",
        kind: :parent,
        edit_scope: %i[repo_alpha repo_beta],
        status: :todo,
        child_refs: %w[A3-v2#3020 A3-v2#3021]
      )
    ]
  end

  it "explains when a child task is blocked by a running sibling" do
    assessment = described_class.evaluate(task: tasks[1], tasks: tasks)

    expect(assessment.runnable?).to eq(false)
    expect(assessment.reason).to eq(:sibling_running)
    expect(assessment.phase).to eq(:implementation)
    expect(assessment.blocking_task_refs).to eq(["A3-v2#3020"])
  end

  it "explains when a parent task waits for unfinished children" do
    assessment = described_class.evaluate(task: tasks[2], tasks: tasks)

    expect(assessment.runnable?).to eq(false)
    expect(assessment.reason).to eq(:parent_waiting_for_children)
    expect(assessment.phase).to eq(:review)
    expect(assessment.blocking_task_refs).to eq(%w[A3-v2#3020 A3-v2#3021])
  end

  it "marks legacy child review tasks as not runnable" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3030",
      kind: :single,
      edit_scope: [:repo_alpha],
      status: :in_review
    )

    assessment = described_class.evaluate(task: task, tasks: [task])

    expect(assessment.runnable?).to eq(false)
    expect(assessment.reason).to eq(:not_runnable_status)
    expect(assessment.phase).to be_nil
  end

  it "blocks a task when kanban blockers are still unresolved" do
    blocker = A3::Domain::Task.new(
      ref: "A3-v2#3039",
      kind: :single,
      edit_scope: [:repo_alpha],
      status: :todo
    )
    task = A3::Domain::Task.new(
      ref: "A3-v2#3040",
      kind: :single,
      edit_scope: [:repo_beta],
      status: :todo,
      blocking_task_refs: [blocker.ref]
    )

    assessment = described_class.evaluate(task: task, tasks: [blocker, task])

    expect(assessment.runnable?).to eq(false)
    expect(assessment.reason).to eq(:blocked_by_tasks)
    expect(assessment.phase).to eq(:implementation)
    expect(assessment.blocking_task_refs).to eq([blocker.ref])
  end

  it "inherits unresolved parent blockers when evaluating a child task" do
    parent_blocker = A3::Domain::Task.new(
      ref: "A3-v2#3044",
      kind: :single,
      edit_scope: [:repo_alpha],
      status: :todo
    )
    parent = A3::Domain::Task.new(
      ref: "A3-v2#3045",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      status: :todo,
      child_refs: ["A3-v2#3046"],
      blocking_task_refs: [parent_blocker.ref]
    )
    child = A3::Domain::Task.new(
      ref: "A3-v2#3046",
      kind: :child,
      edit_scope: [:repo_beta],
      status: :todo,
      parent_ref: parent.ref
    )

    assessment = described_class.evaluate(task: child, tasks: [parent_blocker, parent, child])

    expect(assessment.runnable?).to eq(false)
    expect(assessment.reason).to eq(:blocked_by_tasks)
    expect(assessment.blocking_task_refs).to eq([parent_blocker.ref])
  end

  it "blocks a child task when its parent task is blocked" do
    parent = A3::Domain::Task.new(
      ref: "A3-v2#3047",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      status: :blocked,
      child_refs: ["A3-v2#3048"]
    )
    child = A3::Domain::Task.new(
      ref: "A3-v2#3048",
      kind: :child,
      edit_scope: [:repo_beta],
      status: :todo,
      parent_ref: parent.ref
    )

    assessment = described_class.evaluate(task: child, tasks: [parent, child])

    expect(assessment.runnable?).to eq(false)
    expect(assessment.reason).to eq(:blocked_by_tasks)
    expect(assessment.blocking_task_refs).to eq([parent.ref])
  end

  it "does not mark topology-only tasks as runnable" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3043",
      kind: :single,
      edit_scope: [:repo_alpha],
      status: :todo,
      automation_enabled: false
    )

    assessment = described_class.evaluate(task: task, tasks: [task])

    expect(assessment.runnable?).to eq(false)
    expect(assessment.reason).to eq(:not_trigger_selected)
    expect(assessment.phase).to eq(:implementation)
  end

  it "treats a missing cached child as pending once parent topology is known" do
    parent = A3::Domain::Task.new(
      ref: "A3-v2#3040",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      status: :todo,
      child_refs: %w[A3-v2#3041 A3-v2#3042]
    )
    cached_child = A3::Domain::Task.new(
      ref: "A3-v2#3041",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :done,
      parent_ref: parent.ref
    )

    assessment = described_class.evaluate(task: parent, tasks: [parent, cached_child])

    expect(assessment.runnable?).to eq(false)
    expect(assessment.reason).to eq(:parent_waiting_for_children)
    expect(assessment.phase).to eq(:review)
    expect(assessment.blocking_task_refs).to eq(["A3-v2#3042"])
  end
end
