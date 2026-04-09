# frozen_string_literal: true

require "tmpdir"
require "yaml"

RSpec.describe A3::CLI do
  let(:worker_gateway) { instance_double("WorkerGateway") }
  let(:command_runner) { instance_double("CommandRunner") }
  let(:merge_runner) { instance_double("MergeRunner") }

  it "executes runnable tasks until idle through sqlite backend" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      seed_context(dir)
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        build_child_task(
          ref: "A3-v2#3030",
          edit_scope: [:repo_alpha],
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
      allow(command_runner).to receive(:run).and_return(
        A3::Application::ExecutionResult.new(
          success: true,
          summary: "verification completed"
        )
      )
      allow(merge_runner).to receive(:run).and_return(
        A3::Application::ExecutionResult.new(
          success: true,
          summary: "merge completed"
        )
      )

      out = StringIO.new
      described_class.start(
        [
          "execute-until-idle",
          File.join(dir, "manifest.yml"),
          "--storage-backend", "sqlite",
          "--storage-dir", dir,
          *repo_source_args(repo_sources),
          "--preset-dir", File.join(dir, "presets"),
          "--max-steps", "5"
        ],
        out: out,
        worker_gateway: worker_gateway,
        command_runner: command_runner,
        merge_runner: merge_runner
      )

      expect(out.string).to include("executed 4 task(s); idle=true stop_reason=idle")
      expect(out.string).to include("quarantined=1")
      expect(out.string).to include("steps=A3-v2#3030:implementation")
      expect(task_repository.fetch("A3-v2#3030").status).to eq(:done)
      expect(Pathname(dir).join("quarantine", "A3-v2-3030")).to exist
    end
  end

  it "executes a parent task from review through merge after children are done" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      seed_context(dir)
      File.write(
        File.join(dir, "manifest.yml"),
        YAML.dump(
          {
            "presets" => ["base"],
            "core" => {
              "merge_target" => "merge_to_live",
              "merge_policy" => "ff_only"
            }
          }
        )
      )
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        build_child_task(
          ref: "A3-v2#3030",
          edit_scope: [:repo_alpha],
          status: :done,
          parent_ref: "A3-v2#3022"
        )
      )
      task_repository.save(
        build_child_task(
          ref: "A3-v2#3031",
          edit_scope: [:repo_beta],
          status: :done,
          parent_ref: "A3-v2#3022"
        )
      )
      task_repository.save(
        build_parent_task(
          ref: "A3-v2#3022",
          status: :todo,
          child_refs: %w[A3-v2#3030 A3-v2#3031]
        )
      )

      allow(worker_gateway).to receive(:run).and_return(
        A3::Application::ExecutionResult.new(
          success: true,
          summary: "parent review completed"
        )
      )
      allow(command_runner).to receive(:run).and_return(
        A3::Application::ExecutionResult.new(
          success: true,
          summary: "parent verification completed"
        )
      )
      allow(merge_runner).to receive(:run).and_return(
        A3::Application::ExecutionResult.new(
          success: true,
          summary: "parent merge completed"
        )
      )

      out = StringIO.new
      described_class.start(
        [
          "execute-until-idle",
          File.join(dir, "manifest.yml"),
          "--storage-backend", "sqlite",
          "--storage-dir", dir,
          *repo_source_args(repo_sources),
          "--preset-dir", File.join(dir, "presets"),
          "--max-steps", "5"
        ],
        out: out,
        worker_gateway: worker_gateway,
        command_runner: command_runner,
        merge_runner: merge_runner
      )

      expect(out.string).to include("executed 3 task(s); idle=true stop_reason=idle")
      expect(out.string).to include("steps=A3-v2#3022:review,A3-v2#3022:verification,A3-v2#3022:merge")
      expect(task_repository.fetch("A3-v2#3022").status).to eq(:done)
      expect(Pathname(dir).join("quarantine", "A3-v2-3022")).to exist
    end
  end

  it "processes a filtered kanban queue through implementation, review, verification, and merge" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      seed_context(dir)
      File.write(
        File.join(dir, "manifest.yml"),
        YAML.dump(
          {
            "presets" => ["base"],
            "core" => {
              "merge_target" => "merge_to_live",
              "merge_policy" => "ff_only"
            }
          }
        )
      )
      fake_cli = create_fake_kanban_cli(
        dir,
        mutate_state_on_transition: true,
        snapshots: [
          {
            "id" => 5001,
            "ref" => "Sample#5001",
            "status" => "To do",
            "labels" => ["repo:ui-app", "trigger:auto-scheduler-canary"],
            "parent_ref" => nil
          },
          {
            "id" => 5002,
            "ref" => "Sample#5002",
            "status" => "To do",
            "labels" => ["repo:both", "trigger:auto-scheduler-canary"],
            "parent_ref" => nil
          },
          {
            "id" => 5003,
            "ref" => "Sample#5003",
            "status" => "Done",
            "labels" => ["repo:ui-app", "trigger:auto-scheduler-canary"],
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
      allow(command_runner).to receive(:run).and_return(
        A3::Application::ExecutionResult.new(
          success: true,
          summary: "verification completed"
        )
      )
      allow(merge_runner).to receive(:run).and_return(
        A3::Application::ExecutionResult.new(
          success: true,
          summary: "merge completed"
        )
      )

      out = StringIO.new
      with_env(fake_cli.fetch(:env)) do
        described_class.start(
          [
            "execute-until-idle",
            File.join(dir, "manifest.yml"),
            "--storage-backend", "sqlite",
            "--storage-dir", dir,
            *repo_source_args(repo_sources),
            "--preset-dir", File.join(dir, "presets"),
            "--kanban-command", "ruby",
            "--kanban-command-arg", fake_cli.fetch(:script_path),
            "--kanban-project", "Sample",
            "--kanban-status", "To do",
            "--kanban-trigger-label", "trigger:auto-scheduler-canary",
            "--kanban-repo-label", "repo:ui-app=repo_beta",
            "--kanban-repo-label", "repo:both=repo_alpha,repo_beta",
            "--kanban-working-dir", dir,
            "--max-steps", "12"
          ],
          out: out,
          worker_gateway: worker_gateway,
          command_runner: command_runner,
          merge_runner: merge_runner
        )
      end

      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      transitions = read_fake_kanban_transitions(fake_cli.fetch(:transitions_path))
      comments = read_fake_kanban_comments(fake_cli.fetch(:comments_path))

      expect(out.string).to include("executed 8 task(s); idle=true stop_reason=idle")
      expect(out.string).to include(
        "steps=Sample#5001:implementation,Sample#5001:review,Sample#5001:verification,Sample#5001:merge," \
        "Sample#5002:implementation,Sample#5002:review,Sample#5002:verification,Sample#5002:merge"
      )
      expect(task_repository.fetch("Sample#5001").status).to eq(:done)
      expect(task_repository.fetch("Sample#5002").status).to eq(:done)
      expect(task_repository.all.map(&:ref)).not_to include("Sample#5003")
      expect(transitions.map { |item| item.fetch("argv").last }).to eq(
        ["In progress", "In review", "In review", "Inspection", "Inspection", "Merging", "Merging", "Done",
         "In progress", "In review", "In review", "Inspection", "Inspection", "Merging", "Merging", "Done"]
      )
      expect(comments.fetch("5001").size).to eq(8)
      expect(comments.fetch("5002").size).to eq(8)
      expect(comments).not_to have_key("5003")
    end
  end

  it "does not advance a parent canary when its child is outside the selected status but still unfinished" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      seed_context(dir)
      fake_cli = create_fake_kanban_cli(
        dir,
        mutate_state_on_transition: true,
        snapshots: [
          {
            "id" => 5100,
            "ref" => "Sample#5100",
            "status" => "To do",
            "labels" => ["repo:both", "trigger:auto-parent"],
            "parent_ref" => nil
          },
          {
            "id" => 5101,
            "ref" => "Sample#5101",
            "status" => "In review",
            "labels" => ["repo:ui-app", "trigger:auto-implement"],
            "parent_ref" => "Sample#5100"
          }
        ]
      )

      out = StringIO.new
      with_env(fake_cli.fetch(:env)) do
        described_class.start(
          [
            "execute-until-idle",
            File.join(dir, "manifest.yml"),
            "--storage-backend", "sqlite",
            "--storage-dir", dir,
            *repo_source_args(repo_sources),
            "--preset-dir", File.join(dir, "presets"),
            "--kanban-command", "ruby",
            "--kanban-command-arg", fake_cli.fetch(:script_path),
            "--kanban-project", "Sample",
            "--kanban-status", "To do",
            "--kanban-trigger-label", "trigger:auto-implement",
            "--kanban-trigger-label", "trigger:auto-parent",
            "--kanban-repo-label", "repo:ui-app=repo_beta",
            "--kanban-repo-label", "repo:both=repo_alpha,repo_beta",
            "--kanban-working-dir", dir,
            "--max-steps", "4"
          ],
          out: out,
          worker_gateway: worker_gateway,
          command_runner: command_runner,
          merge_runner: merge_runner
        )
      end

      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      parent = task_repository.fetch("Sample#5100")
      transitions = read_fake_kanban_transitions(fake_cli.fetch(:transitions_path))

      expect(out.string).to include("executed 0 task(s); idle=true stop_reason=idle")
      expect(parent.kind).to eq(:parent)
      expect(parent.child_refs).to eq(["Sample#5101"])
      expect(parent.status).to eq(:todo)
      expect(transitions).to eq([])
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
            "merge_policy" => "ff_only"
          }
        }
      )
    )
  end
end
