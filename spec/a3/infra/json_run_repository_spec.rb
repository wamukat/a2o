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

  it "treats truncated JSON as an empty run store" do
    File.write(File.join(@tmpdir, "runs.json"), '{ "run-1": { "ref": "run-1", "artifact_id": "worker-abc')

    expect(repository.all).to eq([])
    expect(repository.corrupt_run_refs).to eq([])
    expect { repository.fetch("run-1") }.to raise_error(A3::Domain::RecordNotFound)
  end

  it "skips malformed run records and exposes their refs for repair" do
    valid_run = build_run("run-valid")
    File.write(
      File.join(@tmpdir, "runs.json"),
      JSON.pretty_generate(
        "run-corrupt" => ["not", "a", "hash"],
        "run-valid" => A3::Adapters::RunRecord.dump(valid_run)
      )
    )

    expect(repository.all.map(&:ref)).to eq(["run-valid"])
    expect(repository.corrupt_run_refs).to eq(["run-corrupt"])
    expect { repository.fetch("run-corrupt") }.to raise_error(A3::Domain::RecordNotFound)
  end

  it "writes records atomically through a temporary file rename" do
    repository.save(build_run("run-1"))

    expect(Dir.children(@tmpdir).grep(/runs\.json.*\.tmp/)).to eq([])
    expect(JSON.parse(File.read(File.join(@tmpdir, "runs.json"))).keys).to eq(["run-1"])
  end

  it "quarantines corrupt stores before writing a new run" do
    File.write(File.join(@tmpdir, "runs.json"), '{ "run-1": { "ref": "run-1"')

    repository.save(build_run("run-2"))

    expect(JSON.parse(File.read(File.join(@tmpdir, "runs.json"))).keys).to eq(["run-2"])
    quarantined = Dir.children(@tmpdir).grep(/runs\.json\.corrupt\./)
    expect(quarantined.size).to eq(1)
    expect(File.read(File.join(@tmpdir, quarantined.first))).to eq('{ "run-1": { "ref": "run-1"')
  end

  it "serializes concurrent read-modify-write updates" do
    threads = 10.times.map do |index|
      Thread.new { repository.save(build_run("run-#{index}")) }
    end

    threads.each(&:join)

    expect(repository.all.map(&:ref)).to contain_exactly(*10.times.map { |index| "run-#{index}" })
  end
end
