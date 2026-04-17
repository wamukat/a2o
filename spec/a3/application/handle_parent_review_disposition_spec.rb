# frozen_string_literal: true

RSpec.describe A3::Application::HandleParentReviewDisposition do
  let(:writer) { instance_double(A3::Infra::KanbanCliFollowUpChildWriter) }

  subject(:use_case) { described_class.new(follow_up_child_writer: writer) }

  let(:task) do
    A3::Domain::Task.new(
      ref: "Sample#3140",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      status: :in_review,
      current_run_ref: "run-parent-review-1",
      external_task_id: 3140
    )
  end

  let(:run) do
    A3::Domain::Run.new(
      ref: "run-parent-review-1",
      task_ref: task.ref,
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a3/parent/Sample-3140",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: %i[repo_alpha repo_beta],
        verification_scope: %i[repo_alpha repo_beta],
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
  end

  it "returns todo plus follow-up child refs for slot-scoped findings" do
    disposition = A3::Domain::ReviewDisposition.new(
      kind: :follow_up_child,
      repo_scope: :repo_beta,
      summary: "redirect regression",
      description: "legacy malformed params should redirect",
      finding_key: "finding-1"
    )
    allow(writer).to receive(:call).and_return(
      A3::Infra::KanbanCliFollowUpChildWriter::Result.new(
        success?: true,
        child_refs: ["Sample#3200"],
        child_fingerprints: ["Sample#3140|run-parent-review-1|repo_beta|finding-1"]
      )
    )

    result = use_case.call(task: task, run: run, disposition: disposition)

    expect(result.terminal_status).to eq(:todo)
    expect(result.terminal_outcome).to eq(:follow_up_child)
    expect(result.follow_up_child_refs).to eq(["Sample#3200"])
    expect(result.follow_up_child_fingerprints).to eq(["Sample#3140|run-parent-review-1|repo_beta|finding-1"])
  end

  it "returns blocked for unresolved findings" do
    disposition = A3::Domain::ReviewDisposition.new(
      kind: :blocked,
      repo_scope: :unresolved,
      summary: "scope unresolved",
      description: "cross-repo architecture issue",
      finding_key: "finding-2"
    )

    result = use_case.call(task: task, run: run, disposition: disposition)

    expect(result.terminal_status).to eq(:blocked)
    expect(result.terminal_outcome).to eq(:blocked)
    expect(result.blocked_diagnosis).not_to be_nil
  end

  it "returns blocked when the review disposition is missing" do
    result = use_case.call(task: task, run: run, disposition: nil)

    expect(result.terminal_status).to eq(:blocked)
    expect(result.terminal_outcome).to eq(:blocked)
    expect(result.blocked_diagnosis.diagnostic_summary).to eq("parent review disposition is missing or invalid")
  end
end
