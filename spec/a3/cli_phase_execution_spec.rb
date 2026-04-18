# frozen_string_literal: true

require "tmpdir"
require "yaml"
require "shellwords"

RSpec.describe A3::CLI do
  let(:command_runner) { instance_double("CommandRunner") }
  let(:merge_runner) { instance_double("MergeRunner") }

  it "runs verification end-to-end through sqlite backend" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      seed_merge_child_context(dir)
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      run_repository = A3::Infra::SqliteRunRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha, :repo_beta],
          status: :verifying,
          current_run_ref: "run-verification-1",
          parent_ref: "A3-v2#3022"
        )
      )
      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-verification-1",
          task_ref: "A3-v2#3025",
          phase: :verification,
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :runtime_workspace,
            source_type: :integration_record,
            ref: "refs/heads/a2o/work/3025",
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
            owner_ref: "A3-v2#3022",
            owner_scope: :task,
            snapshot_version: "head456"
          )
        )
      )
      allow(command_runner).to receive(:run).and_return(
        A3::Application::ExecutionResult.new(
          success: true,
          summary: "commands/apply-remediation ok"
        )
      )
      allow(command_runner).to receive(:run).with(
        ["commands/verify-all"],
        workspace: an_instance_of(A3::Domain::PreparedWorkspace)
      ).and_return(
        A3::Application::ExecutionResult.new(
          success: true,
          summary: "commands/verify-all ok"
        )
      )

      out = StringIO.new
      described_class.start(
        [
          "run-verification",
          "A3-v2#3025",
          "run-verification-1",
          File.join(dir, "project.yaml"),
          "--storage-backend", "sqlite",
          "--storage-dir", dir,
          *repo_source_args(repo_sources),
          "--preset-dir", File.join(dir, "presets")
        ],
        out: out,
        command_runner: command_runner,
        merge_runner: merge_runner
      )

      expect(out.string).to include("verification completed run-verification-1")
      expect(task_repository.fetch("A3-v2#3025").status).to eq(:merging)
    end
  end

  it "runs merge end-to-end through sqlite backend" do
    Dir.mktmpdir do |dir|
      create_git_repo_source(dir, name: "repo-alpha-source", file_content: "repo_alpha source\n")
      create_git_repo_source(dir, name: "repo-beta-source", file_content: "repo_beta source\n")
      repo_sources = {
        repo_alpha: File.join(dir, "repo-alpha-source"),
        repo_beta: File.join(dir, "repo-beta-source")
      }
      seed_merge_child_context(dir)
      repo_sources.each_value do |repo_path|
        head = `git -C #{Shellwords.escape(repo_path)} rev-parse HEAD`.strip
        system("git", "-C", repo_path, "update-ref", "refs/heads/a2o/parent/A3-v2-3022", head, exception: true, out: File::NULL, err: File::NULL)
        system("git", "-C", repo_path, "update-ref", "refs/heads/a2o/work/3025", head, exception: true, out: File::NULL, err: File::NULL)
      end
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      run_repository = A3::Infra::SqliteRunRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          status: :merging,
          current_run_ref: "run-merge-1",
          parent_ref: "A3-v2#3022"
        )
      )
      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-merge-1",
          task_ref: "A3-v2#3025",
          phase: :merge,
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :runtime_workspace,
            source_type: :integration_record,
            ref: "refs/heads/a2o/work/3025",
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
            owner_ref: "A3-v2#3022",
            owner_scope: :task,
            snapshot_version: "head456"
          )
        )
      )
      allow(merge_runner).to receive(:run).with(
        an_instance_of(A3::Domain::MergePlan),
        workspace: an_instance_of(A3::Domain::PreparedWorkspace)
      ).and_return(
        A3::Application::ExecutionResult.new(
          success: true,
          summary: "merged refs/heads/a2o/work/3025 into refs/heads/a2o/parent/A3-v2#3022"
        )
      )

      out = StringIO.new
      described_class.start(
        [
          "run-merge",
          "A3-v2#3025",
          "run-merge-1",
          File.join(dir, "project.yaml"),
          "--storage-backend", "sqlite",
          "--storage-dir", dir,
          *repo_source_args(repo_sources),
          "--preset-dir", File.join(dir, "presets")
        ],
        out: out,
        command_runner: command_runner,
        merge_runner: merge_runner
      )

      expect(out.string).to include("merge completed run-merge-1")
      expect(task_repository.fetch("A3-v2#3025").status).to eq(:done)
    end
  end

  it "accepts kanban bridge options when running merge directly" do
    Dir.mktmpdir do |dir|
      create_git_repo_source(dir, name: "repo-alpha-source", file_content: "repo_alpha source\n")
      repo_sources = {
        repo_alpha: File.join(dir, "repo-alpha-source")
      }
      seed_merge_child_context(dir)
      head = `git -C #{Shellwords.escape(repo_sources.fetch(:repo_alpha))} rev-parse HEAD`.strip
      system("git", "-C", repo_sources.fetch(:repo_alpha), "update-ref", "refs/heads/a2o/parent/A3-v2-3022", head, exception: true, out: File::NULL, err: File::NULL)
      system("git", "-C", repo_sources.fetch(:repo_alpha), "update-ref", "refs/heads/a2o/work/3028", head, exception: true, out: File::NULL, err: File::NULL)
      kanban_stub = File.join(dir, "kanban_stub.py")
      File.write(
        kanban_stub,
        <<~PY
          #!/usr/bin/env python3
          import json
          import sys

          command = sys.argv[1]
          if command == "task-snapshot-list":
            print(json.dumps([{"id": 3028, "ref": "A3-v2#3028"}]))
          elif command == "task-get":
            print(json.dumps({"id": 3028, "ref": "A3-v2#3028"}))
          elif command == "task-transition":
            print(json.dumps({"ok": True}))
          elif command == "task-label-list":
            print(json.dumps([]))
          elif command == "task-label-add":
            print(json.dumps([]))
          elif command == "task-label-remove":
            print(json.dumps([]))
          elif command == "task-comment-create":
            print(json.dumps({"id": 1, "comment": "ok"}))
          else:
            raise SystemExit(f"unsupported command: {command}")
        PY
      )
      FileUtils.chmod("+x", kanban_stub)
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      run_repository = A3::Infra::SqliteRunRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3028",
          kind: :child,
          edit_scope: [:repo_alpha],
          status: :merging,
          current_run_ref: "run-merge-2",
          parent_ref: "A3-v2#3022"
        )
      )
      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-merge-2",
          task_ref: "A3-v2#3028",
          phase: :merge,
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :runtime_workspace,
            source_type: :integration_record,
            ref: "refs/heads/a2o/work/3028",
            task_ref: "A3-v2#3028"
          ),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(
            edit_scope: [:repo_alpha],
            verification_scope: [:repo_alpha],
            ownership_scope: :task
          ),
          review_target: A3::Domain::ReviewTarget.new(
            base_commit: "base3028",
            head_commit: "head3028",
            task_ref: "A3-v2#3028",
            phase_ref: :review
          ),
          artifact_owner: A3::Domain::ArtifactOwner.new(
            owner_ref: "A3-v2#3022",
            owner_scope: :task,
            snapshot_version: "head3028"
          )
        )
      )
      allow(merge_runner).to receive(:run).and_return(
        A3::Application::ExecutionResult.new(
          success: true,
          summary: "merged refs/heads/a2o/work/3028 into refs/heads/a2o/parent/A3-v2-3022"
        )
      )

      out = StringIO.new
      described_class.start(
        [
          "run-merge",
          "A3-v2#3028",
          "run-merge-2",
          File.join(dir, "project.yaml"),
          "--storage-backend", "sqlite",
          "--storage-dir", dir,
          *repo_source_args(repo_sources),
          "--preset-dir", File.join(dir, "presets"),
          "--kanban-command", "python3",
          "--kanban-command-arg", kanban_stub,
          "--kanban-project", "Sample",
          "--kanban-working-dir", dir,
          "--kanban-trigger-label", "trigger:auto-implement",
          "--kanban-repo-label", "repo:alpha=repo_alpha"
        ],
        out: out,
        command_runner: command_runner,
        merge_runner: merge_runner
      )

      expect(out.string).to include("merge completed run-merge-2")
      expect(task_repository.fetch("A3-v2#3028").status).to eq(:done)
    end
  end

  def seed_merge_child_context(dir)
    preset_dir = File.join(dir, "presets")
    FileUtils.mkdir_p(preset_dir)
    File.write(
      File.join(preset_dir, "base.yml"),
      YAML.dump(
        {
          "schema_version" => "1",
          "implementation_skill" => "skills/implementation/base.md",
          "review_skill" => "skills/review/default.md",
          "verification_commands" => ["commands/verify-all"],
          "remediation_commands" => ["commands/apply-remediation"],
          "workspace_hook" => "hooks/prepare-runtime.sh"
        }
      )
    )
    File.write(
      File.join(dir, "project.yaml"),
      YAML.dump(
        { "schema_version" => 1, "runtime" => { "presets" => ["base"], "merge" => { "target" => "merge_to_parent", "policy" => "ff_only", "target_ref" => "refs/heads/a2o/parent/A3-v2-3022" } } }
      )
    )
  end
end
