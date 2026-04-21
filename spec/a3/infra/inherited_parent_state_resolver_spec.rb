# frozen_string_literal: true

require "shellwords"
require "tmpdir"

RSpec.describe A3::Infra::InheritedParentStateResolver do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  let(:repo_alpha) { File.join(@tmpdir, "repo-alpha") }
  let(:repo_beta) { File.join(@tmpdir, "repo-beta") }
  let(:resolver) do
    described_class.new(
      repo_sources: {
        repo_alpha: repo_alpha,
        repo_beta: repo_beta
      }
    )
  end
  let(:task) do
    A3::Domain::Task.new(
      ref: "Sample#21",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :todo,
      parent_ref: "Sample#10"
    )
  end
  let(:parent_ref) { "refs/heads/a2o/parent/Sample-10" }

  before do
    [repo_alpha, repo_beta].each do |path|
      system("git", "init", path, exception: true, out: File::NULL, err: File::NULL)
      File.write(File.join(path, "README.md"), "# test\n")
      system("git", "-C", path, "add", "README.md", exception: true, out: File::NULL, err: File::NULL)
      system("git", "-C", path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init", exception: true, out: File::NULL, err: File::NULL)
      head = `git -C #{Shellwords.escape(path)} rev-parse HEAD`.strip
      system("git", "-C", path, "update-ref", parent_ref, head, exception: true, out: File::NULL, err: File::NULL)
    end
  end

  it "captures the inherited parent state across all inherited slots for implementation" do
    snapshot = resolver.snapshot_for(task: task, phase: :implementation)

    expect(snapshot.ref).to eq(parent_ref)
    expect(snapshot.heads_by_slot).to eq(
      "repo_alpha" => `git -C #{Shellwords.escape(repo_alpha)} rev-parse #{parent_ref}^{commit}`.strip,
      "repo_beta" => `git -C #{Shellwords.escape(repo_beta)} rev-parse #{parent_ref}^{commit}`.strip
    )
  end

  it "returns nil for merge-recovery verification against a custom source" do
    verification_task = A3::Domain::Task.new(
      ref: task.ref,
      kind: :child,
      edit_scope: task.edit_scope,
      verification_scope: task.verification_scope,
      status: :verifying,
      parent_ref: task.parent_ref,
      verification_source_ref: "refs/heads/main"
    )

    expect(resolver.snapshot_for(task: verification_task, phase: :verification)).to be_nil
  end

  it "captures support-slot divergence in the state fingerprint" do
    File.write(File.join(repo_beta, "OTHER.md"), "changed\n")
    system("git", "-C", repo_beta, "add", "OTHER.md", exception: true, out: File::NULL, err: File::NULL)
    system("git", "-C", repo_beta, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "diverge", exception: true, out: File::NULL, err: File::NULL)
    beta_head = `git -C #{Shellwords.escape(repo_beta)} rev-parse HEAD`.strip
    system("git", "-C", repo_beta, "update-ref", parent_ref, beta_head, exception: true, out: File::NULL, err: File::NULL)

    snapshot = resolver.snapshot_for(task: task, phase: :implementation)

    expect(snapshot.heads_by_slot.fetch("repo_alpha")).not_to eq(snapshot.heads_by_slot.fetch("repo_beta"))
    expect(snapshot.fingerprint).to include("repo_alpha=")
    expect(snapshot.fingerprint).to include("repo_beta=")
  end
end
