# frozen_string_literal: true

RSpec.describe A3::Domain::EvidenceRecord do
  let(:scope_snapshot) do
    A3::Domain::ScopeSnapshot.new(
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha, :repo_beta],
      ownership_scope: :task
    )
  end

  let(:review_target) do
    A3::Domain::ReviewTarget.new(
      base_commit: "base123",
      head_commit: "head456",
      task_ref: "A3-v2#3025",
      phase_ref: :review
    )
  end

  let(:runtime_source) do
    A3::Domain::SourceDescriptor.runtime_detached_commit(
      task_ref: "A3-v2#3025",
      ref: "head456"
    )
  end

  let(:artifact_owner) do
    A3::Domain::ArtifactOwner.new(
      owner_ref: "A3-v2#3022",
      owner_scope: :task,
      snapshot_version: "head456"
    )
  end

  it "serializes and restores the run-level persisted form" do
    evidence = described_class.new(
      task_ref: "A3-v2#3025",
      review_target: review_target,
      source_descriptor: runtime_source,
      scope_snapshot: scope_snapshot,
      artifact_owner: artifact_owner,
      phase_records: [
        A3::Domain::PhaseRecord.new(
          phase: :review,
          source_descriptor: runtime_source,
          scope_snapshot: scope_snapshot,
          verification_summary: "review completed",
          execution_record: A3::Domain::PhaseExecutionRecord.new(
            summary: "review completed",
            failing_command: nil,
            observed_state: "worker exited 0",
            diagnostics: { "stdout" => "ok" }
          )
        )
      ]
    )

    expect(evidence.persisted_form).to include(
      "task_ref" => "A3-v2#3025",
      "review_target" => {
        "base_commit" => "base123",
        "head_commit" => "head456",
        "task_ref" => "A3-v2#3025",
        "phase_ref" => "review"
      },
      "source_descriptor" => {
        "workspace_kind" => "runtime_workspace",
        "source_type" => "detached_commit",
        "ref" => "head456",
        "task_ref" => "A3-v2#3025"
      }
    )
    expect(described_class.from_persisted_form(evidence.persisted_form)).to eq(evidence)
  end

  it "round-trips persisted evidence without a review target" do
    evidence = described_class.new(
      task_ref: "A3-v2#3025",
      review_target: nil,
      source_descriptor: A3::Domain::SourceDescriptor.implementation(
        task_ref: "A3-v2#3025",
        ref: "refs/heads/a3/work/3025"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :task
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3025",
        owner_scope: :task,
        snapshot_version: "snap-1"
      ),
      phase_records: [
        A3::Domain::PhaseRecord.new(
          phase: :implementation,
          source_descriptor: A3::Domain::SourceDescriptor.implementation(
            task_ref: "A3-v2#3025",
            ref: "refs/heads/a3/work/3025"
          ),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(
            edit_scope: [:repo_alpha],
            verification_scope: [:repo_alpha],
            ownership_scope: :task
          )
        )
      ]
    )

    record = evidence.persisted_form

    expect(record["review_target"]).to be_nil
    expect(described_class.from_persisted_form(record)).to eq(evidence)
  end

  it "builds initial evidence with a first phase record and appends immutably" do
    original = described_class.build_initial(
      task_ref: "A3-v2#3025",
      phase: :implementation,
      source_descriptor: A3::Domain::SourceDescriptor.implementation(
        task_ref: "A3-v2#3025",
        ref: "refs/heads/a3/work/3025"
      ),
      scope_snapshot: scope_snapshot,
      review_target: review_target,
      artifact_owner: artifact_owner
    )

    updated = original.append_phase_execution(
      phase: :review,
      source_descriptor: runtime_source,
      scope_snapshot: scope_snapshot,
      verification_summary: "review completed",
      execution_record: A3::Domain::PhaseExecutionRecord.new(
        summary: "review completed",
        diagnostics: { "stdout" => "ok" }
      )
    )

    expect(original.phase_records.size).to eq(1)
    expect(updated.phase_records.size).to eq(2)
    expect(updated.phase_records.last.phase).to eq(:review)
    expect(updated.phase_records.last.execution_record.summary).to eq("review completed")
  end
end
