# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Infra::SqliteTaskRepository do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  let(:repository) { described_class.new(File.join(@tmpdir, "a3.sqlite3")) }

  it "implements the task repository port" do
    expect(described_class.ancestors).to include(A3::Domain::TaskRepository)
  end

  it "persists and restores a task through sqlite records" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha, :repo_beta],
      status: :in_review,
      current_run_ref: "run-1",
      parent_ref: "A3-v2#3022"
    )

    repository.save(task)

    expect(repository.fetch(task.ref)).to eq(task)
  end

  it "raises RecordNotFound for unknown refs" do
    expect { repository.fetch("A3-v2#9999") }.to raise_error(A3::Domain::RecordNotFound)
  end

  it "deletes persisted tasks by ref" do
    task = A3::Domain::Task.new(ref: "A3-v2#3025", kind: :child, edit_scope: [:repo_alpha])
    repository.save(task)

    repository.delete(task.ref)

    expect { repository.fetch(task.ref) }.to raise_error(A3::Domain::RecordNotFound)
  end
end
