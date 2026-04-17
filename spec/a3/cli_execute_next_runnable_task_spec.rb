# frozen_string_literal: true

require "tmpdir"
require "json"
require "yaml"

RSpec.describe A3::CLI do
  let(:worker_gateway) { instance_double("WorkerGateway") }
  let(:command_runner) { instance_double(A3::Infra::LocalCommandRunner) }

  def successful_worker_result(changed_files: { "repo_alpha" => ["src/main.rb"] })
    A3::Application::ExecutionResult.new(
      success: true,
      summary: "implementation completed",
      response_bundle: {
        "success" => true,
        "summary" => "implementation completed",
        "changed_files" => changed_files
      }
    )
  end

  def write_changed_files(workspace, changed_files)
    changed_files.each do |slot_name, paths|
      repo_root = workspace.slot_paths.fetch(slot_name.to_sym)
      paths.each do |path|
        target = repo_root.join(path)
        target.dirname.mkpath
        target.write("changed by test\n")
      end
    end
  end

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
            "title" => "Direct implementation",
            "description" => "Run the direct implementation path.",
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
      allow(worker_gateway).to receive(:run) do |workspace:, **_kwargs|
        changed_files = { "repo_alpha" => ["src/main.rb"] }
        write_changed_files(workspace, changed_files)
        successful_worker_result(changed_files: changed_files)
      end

      out = StringIO.new
      with_env(fake_cli.fetch(:env)) do
        described_class.start(
          [
            "execute-next-runnable-task",
            File.join(dir, "project.yaml"),
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
      expect(task_repository.fetch("A3-v2#3030").status).to eq(:blocked)
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
            File.join(dir, "project.yaml"),
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

  it "imports a To do kanban task and transitions it to In progress before local publication blocks" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      seed_context(dir)
      fake_cli = create_fake_kanban_cli(
        dir,
        snapshots: [
          {
            "id" => 3046,
            "ref" => "Sample#3046",
            "title" => "UI implementation task",
            "description" => "Run the ui-app direct implementation path.",
            "status" => "To do",
            "labels" => ["repo:ui-app", "trigger:auto-implement"],
            "parent_ref" => nil
          }
        ]
      )
      allow(worker_gateway).to receive(:run) do |workspace:, **_kwargs|
        changed_files = { "repo_beta" => ["src/main.rb"] }
        write_changed_files(workspace, changed_files)
        successful_worker_result(changed_files: changed_files)
      end

      out = StringIO.new
      with_env(fake_cli.fetch(:env)) do
        described_class.start(
          [
            "execute-next-runnable-task",
            File.join(dir, "project.yaml"),
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
      expect(task_repository.fetch("Sample#3046").status).to eq(:blocked)
      expect(transitions.fetch(0).fetch("argv")).to include("task-transition", "--task-id", "3046", "--status", "In progress")
      expect(transitions.fetch(1).fetch("argv")).to include("task-label-add", "--task-id", "3046", "--label", "blocked")
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
            "title" => "Direct implementation",
            "description" => "Run the direct implementation path.",
            "status" => "To do",
            "labels" => ["repo:both", "trigger:auto-implement"],
            "parent_ref" => nil
          }
        ]
      )
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3030",
          kind: :single,
          edit_scope: [:repo_alpha],
          verification_scope: %i[repo_alpha repo_beta],
          status: :todo,
          parent_ref: nil
        )
      )

      allow(command_runner).to receive(:run) do |_commands, workspace:, **_kwargs|
        request = JSON.parse(workspace.root_path.join(".a3", "worker-request.json").read)
        changed_files = { "repo_alpha" => ["src/main.rb"] }
        write_changed_files(workspace, changed_files)
        workspace.root_path.join(".a3", "worker-result.json").write(
          JSON.generate(
            "task_ref" => request.fetch("task_ref"),
            "run_ref" => request.fetch("run_ref"),
            "phase" => request.fetch("phase"),
            "success" => true,
            "summary" => "implementation completed",
            "failing_command" => nil,
            "observed_state" => nil,
            "rework_required" => false,
            "changed_files" => changed_files
          )
        )
        A3::Application::ExecutionResult.new(success: true, summary: "implementation completed")
      end

      out = StringIO.new
      with_env(fake_cli.fetch(:env)) do
        described_class.start(
          [
            "execute-next-runnable-task",
            File.join(dir, "project.yaml"),
            "--storage-backend", "sqlite",
            "--storage-dir", dir,
            *repo_source_args(repo_sources),
            "--preset-dir", File.join(dir, "presets"),
            "--worker-command", "ruby",
            "--worker-command-arg", "-I",
            "--worker-command-arg", "a3-engine/lib",
            "--worker-command-arg", "a3-engine/bin/a3",
            "--worker-command-arg", "worker:stdin-bundle",
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
      expect(task_repository.fetch("A3-v2#3030").status).to eq(:blocked)
    end
  end

  it "transitions the external kanban task to Blocked when local publication is disabled" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      seed_context(dir)
      fake_cli = create_fake_kanban_cli(
        dir,
        snapshots: [
          {
            "id" => 3045,
            "ref" => "Sample#3045",
            "title" => "Both repo implementation task",
            "description" => "Run the both-repo direct implementation path.",
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
          repo_alpha = Path(request["slot_paths"]["repo_alpha"])
          changed = repo_alpha / "src" / "main.rb"
          changed.parent.mkdir(parents=True, exist_ok=True)
          changed.write_text("changed by test\\n")
          result = {
              "task_ref": request["task_ref"],
              "run_ref": request["run_ref"],
              "phase": request["phase"],
              "success": True,
              "summary": "worker command completed",
              "failing_command": None,
              "observed_state": None,
              "rework_required": False,
              "changed_files": {"repo_alpha": ["src/main.rb"]},
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
            File.join(dir, "project.yaml"),
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
      expect(task_repository.fetch("Sample#3045").status).to eq(:blocked)
      expect(transitions.fetch(0).fetch("argv")).to include("task-transition", "--task-id", "3045", "--status", "In progress")
      expect(transitions.fetch(1).fetch("argv")).to include("task-label-add", "--task-id", "3045", "--label", "blocked")
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
            File.join(dir, "project.yaml"),
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
      File.join(dir, "project.yaml"),
      YAML.dump(
        { "schema_version" => 1, "runtime" => { "presets" => ["base"], "merge" => { "target" => "merge_to_live", "policy" => "ff_only", "target_ref" => "refs/heads/feature/prototype" } } }
      )
    )
  end
end
