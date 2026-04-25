# frozen_string_literal: true

RSpec.describe A3::Application::ShowTask do
  subject(:use_case) { described_class.new(task_repository: task_repository, run_repository: run_repository) }

  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:run_repository) { A3::Infra::InMemoryRunRepository.new }

  before do
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#parent",
        kind: :parent,
        edit_scope: %i[repo_alpha repo_beta],
        status: :in_review,
        child_refs: ["A3-v2#child", "A3-v2#legacy-child"]
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

  it "keeps child in_review relations visible as review" do
    child = A3::Domain::Task.new(
      ref: "A3-v2#legacy-child",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :in_review,
      parent_ref: "A3-v2#parent"
    )
    task_repository.save(child)

    result = use_case.call(task_ref: "A3-v2#parent")

    expect(result.topology.children).to include(
      have_attributes(ref: "A3-v2#legacy-child", status: :in_review, current_run_ref: nil)
    )
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

  it "includes current run skill feedback for describe-task output" do
    run = A3::Domain::Run.new(
      ref: "run-1",
      task_ref: "A3-v2#child",
      phase: :implementation,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.ticket_branch_head(task_ref: "A3-v2#child", ref: "refs/heads/a2o/work/A3-v2-child"),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :task
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#child",
        owner_scope: :task,
        snapshot_version: "refs/heads/a2o/work/A3-v2-child"
      )
    ).append_phase_evidence(
      phase: :implementation,
      source_descriptor: A3::Domain::SourceDescriptor.ticket_branch_head(task_ref: "A3-v2#child", ref: "refs/heads/a2o/work/A3-v2-child"),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :task
      ),
      execution_record: A3::Domain::PhaseExecutionRecord.new(
        summary: "implemented",
        skill_feedback: [
          {
            "category" => "missing_context",
            "summary" => "Add project setup guidance.",
            "proposal" => { "target" => "project_skill" }
          }
        ]
      )
    )
    run_repository.save(run)

    result = use_case.call(task_ref: "A3-v2#child")

    expect(result.skill_feedback).to eq([
      {
        "category" => "missing_context",
        "summary" => "Add project setup guidance.",
        "proposal" => { "target" => "project_skill" }
      }
    ])
  end

  it "includes pending feedback from earlier phase records in the current run" do
    source = A3::Domain::SourceDescriptor.ticket_branch_head(task_ref: "A3-v2#child", ref: "refs/heads/a2o/work/A3-v2-child")
    scope = A3::Domain::ScopeSnapshot.new(edit_scope: [:repo_alpha], verification_scope: [:repo_alpha], ownership_scope: :task)
    run = A3::Domain::Run.new(
      ref: "run-1",
      task_ref: "A3-v2#child",
      phase: :review,
      workspace_kind: :ticket_workspace,
      source_descriptor: source,
      scope_snapshot: scope,
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#child",
        owner_scope: :task,
        snapshot_version: "refs/heads/a2o/work/A3-v2-child"
      )
    ).append_phase_evidence(
      phase: :implementation,
      source_descriptor: source,
      scope_snapshot: scope,
      execution_record: A3::Domain::PhaseExecutionRecord.new(
        summary: "implemented",
        skill_feedback: [
          {
            "category" => "missing_context",
            "summary" => "Do not lose this pending feedback.",
            "proposal" => { "target" => "project_skill" }
          }
        ]
      )
    ).append_phase_evidence(
      phase: :review,
      source_descriptor: source,
      scope_snapshot: scope,
      execution_record: A3::Domain::PhaseExecutionRecord.new(summary: "review passed")
    )
    run_repository.save(run)

    result = use_case.call(task_ref: "A3-v2#child")

    expect(result.skill_feedback).to include(
      hash_including("summary" => "Do not lose this pending feedback.")
    )
  end
end
