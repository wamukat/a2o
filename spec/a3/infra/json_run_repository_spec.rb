# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Infra::JsonRunRepository do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  let(:repository) { described_class.new(File.join(@tmpdir, "runs.json")) }

  def build_run(ref)
    A3::Domain::Run.new(
      ref: ref,
      task_ref: "A3-v2#3025",
      phase: :verification,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "head456",
        task_ref: "A3-v2#3025"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha, :repo_beta],
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

  it "persists and restores a run through JSON records" do
    run = A3::Domain::Run.new(
      ref: "run-1",
      task_ref: "A3-v2#3025",
      phase: :verification,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "head456",
        task_ref: "A3-v2#3025"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha, :repo_beta],
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
    ).append_phase_evidence(
      phase: :verification,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "head456",
        task_ref: "A3-v2#3025"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha, :repo_beta],
        ownership_scope: :task
      ),
      verification_summary: "all green"
    )

    repository.save(run)

    expect(repository.fetch(run.ref)).to eq(run)
  end

  it "raises RecordNotFound for unknown refs" do
    expect { repository.fetch("run-9999") }.to raise_error(A3::Domain::RecordNotFound)
  end

  it "returns runs in persistence order rather than ref sort order" do
    repository.save(build_run("run-10"))
    repository.save(build_run("run-2"))

    expect(repository.all.map(&:ref)).to eq(%w[run-10 run-2])
  end
end
