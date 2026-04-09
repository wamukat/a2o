# frozen_string_literal: true

RSpec.describe A3::Infra::InMemoryRunRepository do
  def build_run(ref)
    A3::Domain::Run.new(
      ref: ref,
      task_ref: "A3-v2#3025",
      phase: :implementation,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a3/work/3025",
        task_ref: "A3-v2#3025"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: "A3-v2#3025",
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3025",
        owner_scope: :task,
        snapshot_version: "snap-1"
      )
    )
  end

  it "implements the run repository port" do
    expect(described_class.ancestors).to include(A3::Domain::RunRepository)
  end

  it "stores and fetches immutable run instances by ref" do
    repository = described_class.new
    run = A3::Domain::Run.new(
      ref: "run-1",
      task_ref: "A3-v2#3025",
      phase: :implementation,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a3/work/3025",
        task_ref: "A3-v2#3025"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: "A3-v2#3025",
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3025",
        owner_scope: :task,
        snapshot_version: "snap-1"
      )
    )

    repository.save(run)

    expect(repository.fetch("run-1")).to eq(run)
  end

  it "raises RecordNotFound for unknown refs" do
    repository = described_class.new

    expect { repository.fetch("run-9999") }.to raise_error(A3::Domain::RecordNotFound)
  end

  it "returns runs in persistence order rather than ref sort order" do
    repository = described_class.new
    repository.save(build_run("run-10"))
    repository.save(build_run("run-2"))

    expect(repository.all.map(&:ref)).to eq(%w[run-10 run-2])
  end
end
