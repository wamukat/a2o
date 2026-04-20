# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::CLI do
  it "cleans selected terminal workspace scopes through sqlite backend" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          status: :done
        )
      )

      described_class.start(
        [
          "prepare-workspace",
          "--storage-backend", "sqlite",
          "--storage-dir", dir,
          *repo_source_args(repo_sources),
          "--source-type", "detached_commit",
          "--source-ref", "abc123",
          "--bootstrap-marker", "workspace-hook:v1",
          "A3-v2#3025",
          "review"
        ],
        out: StringIO.new
      )

      out = StringIO.new
      described_class.start(
        [
          "cleanup-terminal-workspaces",
          "--storage-backend", "sqlite",
          "--storage-dir", dir
        ],
        out: out
      )

      expect(out.string).to include("cleanup dry_run=false cleaned=1 statuses=done scopes=ticket_workspace,runtime_workspace")
      expect(out.string).to include("A3-v2#3025 status=done")
      expect(Pathname(dir).join("workspaces", "A3-v2-3025")).not_to exist
    end
  end

  it "keeps cleanup scope names exact instead of normalizing hyphens" do
    expect(described_class.send(:parse_cleanup_list, "ticket-workspace,runtime_workspace")).to eq(
      [:"ticket-workspace", :runtime_workspace]
    )
  end

  it "quarantines done task workspaces through sqlite backend" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          status: :done
        )
      )

      described_class.start(
        [
          "prepare-workspace",
          "--storage-backend", "sqlite",
          "--storage-dir", dir,
          *repo_source_args(repo_sources),
          "--source-type", "detached_commit",
          "--source-ref", "abc123",
          "--bootstrap-marker", "workspace-hook:v1",
          "A3-v2#3025",
          "review"
        ],
        out: StringIO.new
      )

      out = StringIO.new
      described_class.start(
        [
          "quarantine-terminal-workspaces",
          "--storage-backend", "sqlite",
          "--storage-dir", dir
        ],
        out: out
      )

      expect(out.string).to include("quarantined 1 workspace(s)")
      expect(Pathname(dir).join("quarantine", "A3-v2-3025")).to exist
      expect(Pathname(dir).join("workspaces", "A3-v2-3025")).not_to exist
    end
  end
end
