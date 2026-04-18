# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::CLI do
  it "shows scheduler, task tree, next, and running sections from storage state" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json"))
      run_repository = A3::Infra::JsonRunRepository.new(File.join(dir, "runs.json"))

      task_repository.save(
        A3::Domain::Task.new(
          ref: "Sample#3138",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha],
          status: :in_progress,
          current_run_ref: "run-1",
          parent_ref: "Sample#3140"
        )
      )
      task_repository.save(
        A3::Domain::Task.new(
          ref: "Sample#3141",
          kind: :child,
          edit_scope: [:repo_beta],
          verification_scope: [:repo_beta],
          status: :todo,
          parent_ref: "Sample#3140"
        )
      )
      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-1",
          task_ref: "Sample#3138",
          phase: :implementation,
          workspace_kind: :ticket_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :ticket_workspace,
            source_type: :branch_head,
            ref: "refs/heads/a2o/work/Sample-3138",
            task_ref: "Sample#3138"
          ),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(
            edit_scope: [:repo_alpha],
            verification_scope: [:repo_alpha],
            ownership_scope: :task
          ),
          artifact_owner: A3::Domain::ArtifactOwner.new(
            owner_ref: "Sample#3140",
            owner_scope: :task,
            snapshot_version: "refs/heads/a2o/work/Sample-3138"
          )
        )
      )

      out = StringIO.new
      described_class.start(
        ["watch-summary", "--storage-backend", "json", "--storage-dir", dir],
        out: out
      )

      expect(out.string).to include("Scheduler: running")
      expect(out.string).to include("Task Tree")
      expect(out.string).to include("Next")
      expect(out.string).to include("Running")
      expect(out.string).to include("\e[36mScheduler: running\e[0m")
      expect(out.string).to include("▶ #3138")
      expect(out.string).to include("▷ #3141")
      expect(out.string).to include("\e[33m▶ #3138")
      expect(out.string).to include("\e[36m▷ #3141")
      expect(out.string).to include("Merging ─────┐")
      expect(out.string).to include("Implementation ─────┐")
      expect(out.string).to include("- #3141")
      expect(out.string).to include("- #3138 implementation/implementation/running_command hb=?")
    end
  end

  it "loads kanban titles through the watch-summary-specific command" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json"))
      run_repository = A3::Infra::JsonRunRepository.new(File.join(dir, "runs.json"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "Sample#3138",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha],
          status: :blocked,
          external_task_id: 3138
        )
      )

      fake_cli = create_fake_kanban_cli(
        dir,
        snapshots: [
          {
            "id" => 3138,
            "ref" => "Sample#3138",
            "title" => "Kanban title",
            "status" => "To do",
            "labels" => []
          },
          {
            "id" => 4000,
            "ref" => "Sample#4000",
            "title" => "Unrelated task",
            "status" => "To do",
            "labels" => []
          }
        ]
      )

      out = StringIO.new
      with_env(fake_cli.fetch(:env)) do
        described_class.start(
          [
            "watch-summary",
            "--storage-backend", "json",
            "--storage-dir", dir,
            "--kanban-command", "ruby",
            "--kanban-command-arg", fake_cli.fetch(:script_path),
            "--kanban-project", "Sample",
            "--kanban-working-dir", dir,
            "--kanban-repo-label", "repo:ui-app=repo_beta"
          ],
          out: out
        )
      end

      expect(out.string).to include("Kanban title [kanban=To do internal=Blocked]")
      expect(out.string).not_to include("Unrelated task")
    end
  end
end
