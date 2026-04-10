# frozen_string_literal: true

require "tmpdir"
require "yaml"

RSpec.describe A3::CLI do
  let(:worker_gateway) { instance_double("WorkerGateway") }
  let(:command_runner) { instance_double(A3::Infra::LocalCommandRunner) }

  it "executes the next runnable implementation task end-to-end through sqlite backend" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      seed_context(dir)
      fake_cli = create_fake_kanban_cli(
        dir,
        snapshots: [
          {
            "id" => 3030,
            "ref" => "A3-v2#3030",
            "title" => "Direct canary implementation",
            "description" => "Run the direct canary implementation path.",
            "status" => "To do",
            "labels" => ["repo:both", "trigger:auto-implement"],
            "parent_ref" => "A3-v2#3022"
          }
        ]
      )
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3030",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: %i[repo_alpha repo_beta],
          status: :todo,
          parent_ref: "A3-v2#3022"
        )
      )
      allow(worker_gateway).to receive(:run).and_return(
        A3::Application::ExecutionResult.new(
          success: true,
          summary: "implementation completed"
        )
      )

      out = StringIO.new
      with_env(fake_cli.fetch(:env)) do
        described_class.start(
          [
            "execute-next-runnable-task",
            File.join(dir, "manifest.yml"),
            "--storage-backend", "sqlite",
            "--storage-dir", dir,
            *repo_source_args(repo_sources),
            "--preset-dir", File.join(dir, "presets"),
            "--kanban-command", "ruby",
            "--kanban-command-arg", fake_cli.fetch(:script_path),
            "--kanban-project", "A3-v2",
            "--kanban-trigger-label", "trigger:auto-implement",
            "--kanban-repo-label", "repo:both=repo_alpha,repo_beta",
            "--kanban-working-dir", dir
          ],
          out: out,
          worker_gateway: worker_gateway
        )
      end

      expect(out.string).to include("executed next runnable A3-v2#3030 at implementation")
      expect(task_repository.fetch("A3-v2#3030").status).to eq(:verifying)
    end
  end

  it "prints no runnable task when the queue is empty" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      seed_context(dir)
      fake_cli = create_fake_kanban_cli(dir, snapshots: [])

      out = StringIO.new
      with_env(fake_cli.fetch(:env)) do
        described_class.start(
          [
            "execute-next-runnable-task",
            File.join(dir, "manifest.yml"),
            "--storage-backend", "sqlite",
            "--storage-dir", dir,
            *repo_source_args(repo_sources),
            "--preset-dir", File.join(dir, "presets"),
            "--kanban-command", "ruby",
            "--kanban-command-arg", fake_cli.fetch(:script_path),
            "--kanban-project", "A3-v2",
            "--kanban-trigger-label", "trigger:auto-implement",
            "--kanban-repo-label", "repo:both=repo_alpha,repo_beta",
            "--kanban-working-dir", dir
          ],
          out: out,
          worker_gateway: worker_gateway
        )
      end

      expect(out.string).to include("no runnable task")
    end
  end

  it "imports a To do kanban task and transitions it to In progress before execution" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      seed_context(dir)
      fake_cli = create_fake_kanban_cli(
        dir,
        snapshots: [
          {
            "id" => 3046,
            "ref" => "Sample#3046",
            "title" => "UI canary task",
            "description" => "Run the ui-app direct canary.",
            "status" => "To do",
            "labels" => ["repo:ui-app", "trigger:auto-implement"],
            "parent_ref" => nil
          }
        ]
      )
      allow(worker_gateway).to receive(:run).and_return(
        A3::Application::ExecutionResult.new(
          success: true,
          summary: "implementation completed"
        )
      )

      out = StringIO.new
      with_env(fake_cli.fetch(:env)) do
        described_class.start(
          [
            "execute-next-runnable-task",
            File.join(dir, "manifest.yml"),
            "--storage-backend", "sqlite",
            "--storage-dir", dir,
            *repo_source_args(repo_sources),
            "--preset-dir", File.join(dir, "presets"),
            "--kanban-command", "ruby",
            "--kanban-command-arg", fake_cli.fetch(:script_path),
            "--kanban-project", "Sample",
            "--kanban-trigger-label", "trigger:auto-implement",
            "--kanban-repo-label", "repo:ui-app=repo_beta",
            "--kanban-working-dir", dir
          ],
          out: out,
          worker_gateway: worker_gateway
        )
      end

      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      transitions = read_fake_kanban_transitions(fake_cli.fetch(:transitions_path))

      expect(out.string).to include("executed next runnable Sample#3046 at implementation")
      expect(task_repository.fetch("Sample#3046").status).to eq(:verifying)
      expect(transitions.fetch(0).fetch("argv")).to include("task-transition", "--task-id", "3046", "--status", "In progress")
      expect(transitions.fetch(1).fetch("argv")).to include("task-transition", "--task-id", "3046", "--status", "Inspection")
    end
  end

  it "builds the default worker gateway from worker command options" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      seed_context(dir)
      fake_cli = create_fake_kanban_cli(
        dir,
        snapshots: [
          {
            "id" => 3030,
            "ref" => "A3-v2#3030",
            "title" => "Direct canary implementation",
            "description" => "Run the direct canary implementation path.",
            "status" => "To do",
            "labels" => ["repo:both", "trigger:auto-implement"],
            "parent_ref" => "A3-v2#3022"
          }
        ]
      )
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3030",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: %i[repo_alpha repo_beta],
          status: :todo,
          parent_ref: "A3-v2#3022"
        )
      )

      expect(command_runner).to receive(:run).with(
        ["ruby scripts/a3/a3_v2_direct_canary_worker.rb"],
        workspace: an_instance_of(A3::Domain::PreparedWorkspace),
        env: hash_including("A3_WORKER_REQUEST_PATH", "A3_WORKER_RESULT_PATH", "A3_WORKSPACE_ROOT")
      ).and_return(
        A3::Application::ExecutionResult.new(
          success: true,
          summary: "implementation completed"
        )
      )

      out = StringIO.new
      with_env(fake_cli.fetch(:env)) do
        described_class.start(
          [
            "execute-next-runnable-task",
            File.join(dir, "manifest.yml"),
            "--storage-backend", "sqlite",
            "--storage-dir", dir,
            *repo_source_args(repo_sources),
            "--preset-dir", File.join(dir, "presets"),
            "--worker-command", "ruby",
            "--worker-command-arg", "scripts/a3/a3_v2_direct_canary_worker.rb",
            "--kanban-command", "ruby",
            "--kanban-command-arg", fake_cli.fetch(:script_path),
            "--kanban-project", "A3-v2",
            "--kanban-trigger-label", "trigger:auto-implement",
            "--kanban-repo-label", "repo:both=repo_alpha,repo_beta",
            "--kanban-working-dir", dir
          ],
          out: out,
          command_runner: command_runner
        )
      end

      expect(out.string).to include("executed next runnable A3-v2#3030 at implementation")
      expect(task_repository.fetch("A3-v2#3030").status).to eq(:verifying)
    end
  end

  it "transitions the external kanban task to In review when using worker command options" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      seed_context(dir)
      fake_cli = create_fake_kanban_cli(
        dir,
        snapshots: [
          {
            "id" => 3045,
            "ref" => "Sample#3045",
            "title" => "Both repo canary task",
            "description" => "Run the both-repo direct canary.",
            "status" => "To do",
            "labels" => ["repo:both", "trigger:auto-implement"],
            "parent_ref" => nil
          }
        ]
      )
      worker_script = File.join(dir, "direct_worker.py")
      File.write(
        worker_script,
        <<~PYTHON
          #!/usr/bin/env python3
          import json
          import os
          from pathlib import Path

          request = json.loads(Path(os.environ["A3_WORKER_REQUEST_PATH"]).read_text())
          result = {
              "task_ref": request["task_ref"],
              "run_ref": request["run_ref"],
              "phase": request["phase"],
              "success": True,
              "summary": "worker command completed",
              "failing_command": None,
              "observed_state": None,
              "rework_required": False,
              "changed_files": {},
              "diagnostics": {}
          }
          Path(os.environ["A3_WORKER_RESULT_PATH"]).write_text(json.dumps(result))
        PYTHON
      )
      File.chmod(0o755, worker_script)

      out = StringIO.new
      with_env(fake_cli.fetch(:env)) do
        described_class.start(
          [
            "execute-next-runnable-task",
            File.join(dir, "manifest.yml"),
            "--storage-backend", "sqlite",
            "--storage-dir", dir,
            *repo_source_args(repo_sources),
            "--preset-dir", File.join(dir, "presets"),
            "--worker-command", "python3",
            "--worker-command-arg", worker_script,
            "--kanban-command", "ruby",
            "--kanban-command-arg", fake_cli.fetch(:script_path),
            "--kanban-project", "Sample",
            "--kanban-trigger-label", "trigger:auto-implement",
            "--kanban-repo-label", "repo:both=repo_alpha,repo_beta",
            "--kanban-working-dir", dir
          ],
          out: out
        )
      end

      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      transitions = read_fake_kanban_transitions(fake_cli.fetch(:transitions_path))

      expect(out.string).to include("executed next runnable Sample#3045 at implementation")
      expect(task_repository.fetch("Sample#3045").status).to eq(:verifying)
      expect(transitions.fetch(0).fetch("argv")).to include("task-transition", "--task-id", "3045", "--status", "In progress")
      expect(transitions.fetch(1).fetch("argv")).to include("task-transition", "--task-id", "3045", "--status", "Inspection")
    end
  end

  it "fails fast when kanban bridge options are partially configured" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      seed_context(dir)

      expect do
        described_class.start(
          [
            "execute-next-runnable-task",
            File.join(dir, "manifest.yml"),
            "--storage-backend", "sqlite",
            "--storage-dir", dir,
            *repo_source_args(repo_sources),
            "--preset-dir", File.join(dir, "presets"),
            "--kanban-command", "python3"
          ],
          out: StringIO.new,
          worker_gateway: worker_gateway
        )
      end.to raise_error(
        ArgumentError,
        /kanban bridge options require --kanban-command, --kanban-project, and at least one --kanban-repo-label/
      )
    end
  end

  def seed_context(dir)
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
      File.join(dir, "manifest.yml"),
      YAML.dump(
        {
          "presets" => ["base"],
          "core" => {
            "merge_target" => "merge_to_parent",
            "merge_policy" => "ff_only",
            "merge_target_ref" => "refs/heads/feature/prototype"
          }
        }
      )
    )
  end
end
