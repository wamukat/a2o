# frozen_string_literal: true

RSpec.describe A3::Application::ShowTask do
  subject(:use_case) { described_class.new(task_repository: task_repository) }

  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }

  before do
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#parent",
        kind: :parent,
        edit_scope: %i[repo_alpha repo_beta],
        status: :in_review,
        child_refs: ["A3-v2#child"]
      )
    )
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#child",
        kind: :child,
        edit_scope: [:repo_alpha],
        verification_scope: %i[repo_alpha repo_beta],
        status: :blocked,
        current_run_ref: "run-1",
        parent_ref: "A3-v2#parent"
      )
    )
  end

  it "returns operator-facing task view with topology" do
    result = use_case.call(task_ref: "A3-v2#child")

    expect(result.ref).to eq("A3-v2#child")
    expect(result.kind).to eq(:child)
    expect(result.status).to eq(:blocked)
    expect(result.current_run_ref).to eq("run-1")
    expect(result.edit_scope).to eq([:repo_alpha])
    expect(result.verification_scope).to eq(%i[repo_alpha repo_beta])
    expect(result.runnable_assessment.reason).to eq(:already_running)
    expect(result.runnable_assessment.blocking_task_refs).to eq(["run-1"])
    expect(result.topology.parent.ref).to eq("A3-v2#parent")
    expect(result.topology.parent.status).to eq(:in_review)
  end

  it "marks missing child relations explicitly" do
    orphan_parent = A3::Domain::Task.new(
      ref: "A3-v2#orphan-parent",
      kind: :parent,
      edit_scope: [:repo_beta],
      child_refs: ["A3-v2#missing-child"]
    )
    task_repository.save(orphan_parent)

    result = use_case.call(task_ref: orphan_parent.ref)

    expect(result.topology.children.size).to eq(1)
    expect(result.topology.children.first.ref).to eq("A3-v2#missing-child")
    expect(result.topology.children.first.status).to eq(:missing)
    expect(result.runnable_assessment.reason).to eq(:parent_waiting_for_children)
    expect(result.runnable_assessment.blocking_task_refs).to eq(["A3-v2#missing-child"])
  end
end
