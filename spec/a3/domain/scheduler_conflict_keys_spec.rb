# frozen_string_literal: true

RSpec.describe A3::Domain::SchedulerConflictKeys do
  it "uses the task ref as the parent group for parent tasks" do
    parent = A3::Domain::Task.new(
      ref: "A2O#100",
      kind: :parent,
      edit_scope: [:repo_alpha]
    )

    keys = described_class.for_task(task: parent, tasks: [parent])

    expect(keys.task_key).to eq("task:A2O#100")
    expect(keys.parent_group_key).to eq("parent-group:A2O#100")
  end

  it "uses the topmost parent ref as the parent group for child tasks" do
    grandparent = A3::Domain::Task.new(
      ref: "A2O#100",
      kind: :parent,
      edit_scope: [:repo_alpha]
    )
    parent = A3::Domain::Task.new(
      ref: "A2O#101",
      kind: :child,
      edit_scope: [:repo_alpha],
      parent_ref: grandparent.ref
    )
    child = A3::Domain::Task.new(
      ref: "A2O#102",
      kind: :child,
      edit_scope: [:repo_alpha],
      parent_ref: parent.ref
    )

    keys = described_class.for_task(task: child, tasks: [grandparent, parent, child])

    expect(keys.parent_group_key).to eq("parent-group:A2O#100")
  end

  it "uses a single-task group for standalone tasks" do
    task = A3::Domain::Task.new(
      ref: "A2O#200",
      kind: :single,
      edit_scope: [:repo_alpha]
    )

    keys = described_class.for_task(task: task, tasks: [task])

    expect(keys.parent_group_key).to eq("single:A2O#200")
  end
end
