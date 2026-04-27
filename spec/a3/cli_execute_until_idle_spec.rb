# frozen_string_literal: true

require "tmpdir"
require "yaml"
require "shellwords"

RSpec.describe A3::CLI do
  let(:worker_gateway) { instance_double("WorkerGateway") }
  let(:command_runner) { instance_double("CommandRunner") }
  let(:merge_runner) { instance_double("MergeRunner") }

  before do
    allow(worker_gateway).to receive(:agent_owned_publication?).and_return(true)
  end

  it "executes runnable tasks until idle through sqlite backend" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      seed_context(dir)
      write_project_yaml(File.join(dir, "project.yaml"))
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3030",
          kind: :single,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha],
          status: :todo,
          parent_ref: nil
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
          File.join(dir, "project.yaml"),
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
      expect(out.string).to include("quarantined=1")
      expect(out.string).to include("steps=A3-v2#3030:implementation,A3-v2#3030:verification,A3-v2#3030:merge")
      expect(task_repository.fetch("A3-v2#3030").status).to eq(:done)
      expect(Pathname(dir).join("quarantine", "A3-v2-3030")).to exist
    end
  end

  it "executes a single task review gate when enabled" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      seed_context(dir)
      write_project_yaml(File.join(dir, "project.yaml"), review_gate: { "single" => true })
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3030",
          kind: :single,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha],
          status: :todo
        )
      )
      allow(worker_gateway).to receive(:run).and_return(
        A3::Application::ExecutionResult.new(
          success: true,
          summary: "worker phase completed"
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
          File.join(dir, "project.yaml"),
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

      expect(out.string).to include("steps=A3-v2#3030:implementation,A3-v2#3030:review,A3-v2#3030:verification,A3-v2#3030:merge")
      expect(task_repository.fetch("A3-v2#3030").status).to eq(:done)
    end
  end

  it "preserves blocked task workspaces when execute-until-idle reaches idle" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      seed_context(dir)
      write_project_yaml(File.join(dir, "project.yaml"))
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3031",
          kind: :single,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha],
          status: :blocked
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
          "A3-v2#3031",
          "review"
        ],
        out: StringIO.new
      )

      out = StringIO.new
      described_class.start(
        [
          "execute-until-idle",
          File.join(dir, "project.yaml"),
          "--storage-backend", "sqlite",
          "--storage-dir", dir,
          *repo_source_args(repo_sources),
          "--preset-dir", File.join(dir, "presets"),
          "--max-steps", "1"
        ],
        out: out,
        worker_gateway: worker_gateway,
        command_runner: command_runner,
        merge_runner: merge_runner
      )

      expect(out.string).to include("executed 0 task(s); idle=true stop_reason=idle")
      expect(out.string).to include("quarantined=0")
      expect(Pathname(dir).join("workspaces", "A3-v2-3031")).to exist
      expect(Pathname(dir).join("quarantine", "A3-v2-3031")).not_to exist
    end
  end

  it "executes a parent task from review through merge after children are done" do
    Dir.mktmpdir do |dir|
      create_git_repo_source(dir, name: "repo-alpha-source", file_content: "repo_alpha source\n")
      create_git_repo_source(dir, name: "repo-beta-source", file_content: "repo_beta source\n")
      repo_sources = {
        repo_alpha: File.join(dir, "repo-alpha-source"),
        repo_beta: File.join(dir, "repo-beta-source")
      }
      seed_context(dir)
      write_project_yaml(File.join(dir, "project.yaml"))
      repo_sources.each_value do |repo_path|
        head = `git -C #{Shellwords.escape(repo_path)} rev-parse HEAD`.strip
        system("git", "-C", repo_path, "update-ref", "refs/heads/a2o/parent/A3-v2-3022", head, exception: true, out: File::NULL, err: File::NULL)
      end
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
          summary: "parent review completed",
          response_bundle: {
            "review_disposition" => {
              "kind" => "completed",
              "repo_scope" => "repo_alpha",
              "summary" => "No findings",
              "description" => "Parent review completed without outstanding findings.",
              "finding_key" => "completed-no-findings"
            }
          }
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
          File.join(dir, "project.yaml"),
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

  it "processes a filtered kanban queue through implementation, verification, and merge" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      seed_context(dir)
      write_project_yaml(File.join(dir, "project.yaml"))
      fake_cli = create_fake_kanban_cli(
        dir,
        mutate_state_on_transition: true,
        snapshots: [
          {
            "id" => 5001,
            "ref" => "Sample#5001",
            "title" => "Filtered ui-app validation",
            "description" => "Run the filtered ui-app validation path.",
            "status" => "To do",
            "labels" => ["repo:ui-app", "trigger:auto-scheduler-validation"],
            "parent_ref" => nil
          },
          {
            "id" => 5002,
            "ref" => "Sample#5002",
            "title" => "Filtered both-repo validation",
            "description" => "Run the filtered both-repo validation path.",
            "status" => "To do",
            "labels" => ["repo:both", "trigger:auto-scheduler-validation"],
            "parent_ref" => nil
          },
          {
            "id" => 5003,
            "ref" => "Sample#5003",
            "title" => "Completed validation",
            "description" => "Already completed and should be ignored.",
            "status" => "Done",
            "labels" => ["repo:ui-app", "trigger:auto-scheduler-validation"],
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
            File.join(dir, "project.yaml"),
            "--storage-backend", "sqlite",
            "--storage-dir", dir,
            *repo_source_args(repo_sources),
            "--preset-dir", File.join(dir, "presets"),
            "--kanban-command", "ruby",
            "--kanban-command-arg", fake_cli.fetch(:script_path),
            "--kanban-project", "Sample",
            "--kanban-status", "To do",
            "--kanban-trigger-label", "trigger:auto-scheduler-validation",
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
      events = read_fake_kanban_events(fake_cli.fetch(:events_path))

      expect(out.string).to include("executed 6 task(s); idle=true stop_reason=idle")
      expect(out.string).to include(
        "steps=Sample#5001:implementation,Sample#5001:verification,Sample#5001:merge," \
        "Sample#5002:implementation,Sample#5002:verification,Sample#5002:merge"
      )
      expect(task_repository.fetch("Sample#5001").status).to eq(:done)
      expect(task_repository.fetch("Sample#5002").status).to eq(:done)
      expect(task_repository.all.map(&:ref)).not_to include("Sample#5003")
      expect(transitions.map { |item| item.fetch("argv").last }).to eq(
        ["In progress", "Inspection", "Inspection", "Merging", "Merging", "Done",
         "In progress", "Inspection", "Inspection", "Merging", "Merging", "Done"]
      )
      expect(comments.fetch("5001").size).to eq(2)
      expect(comments.fetch("5002").size).to eq(2)
      expect(comments).not_to have_key("5003")
      expect(events.fetch("5001").map { |item| item.fetch("kind") }).to eq(
        %w[task_started task_started task_started task_completed]
      )
      expect(events.fetch("5002").map { |item| item.fetch("kind") }).to eq(
        %w[task_started task_started task_started task_completed]
      )
      expect(events).not_to have_key("5003")
    end
  end

  it "continues an imported unfinished child before advancing its parent validation" do
    Dir.mktmpdir do |dir|
      create_git_repo_source(dir, name: "repo-alpha-source", file_content: "repo_alpha source\n")
      create_git_repo_source(dir, name: "repo-beta-source", file_content: "repo_beta source\n")
      repo_sources = {
        repo_alpha: File.join(dir, "repo-alpha-source"),
        repo_beta: File.join(dir, "repo-beta-source")
      }
      seed_context(dir)
      repo_sources.each_value do |repo_path|
        head = `git -C #{Shellwords.escape(repo_path)} rev-parse HEAD`.strip
        system("git", "-C", repo_path, "update-ref", "refs/heads/a2o/parent/Sample-5100", head, exception: true, out: File::NULL, err: File::NULL)
      end
      fake_cli = create_fake_kanban_cli(
        dir,
        mutate_state_on_transition: true,
        snapshots: [
          {
            "id" => 5100,
            "ref" => "Sample#5100",
            "title" => "Parent validation",
            "description" => "Wait for all child canaries to finish.",
            "status" => "To do",
            "labels" => ["repo:both", "trigger:auto-parent"],
            "parent_ref" => nil
          },
          {
            "id" => 5101,
            "ref" => "Sample#5101",
            "title" => "Child validation still running",
            "description" => "This child is already in verification.",
            "status" => "Inspection",
            "labels" => ["repo:ui-app", "trigger:auto-implement"],
            "parent_ref" => "Sample#5100"
          }
        ]
      )
      allow(worker_gateway).to receive(:run).and_return(
        A3::Application::ExecutionResult.new(
          success: true,
          summary: "implementation completed",
          response_bundle: {
            "review_disposition" => {
              "kind" => "completed",
              "repo_scope" => "repo_alpha",
              "summary" => "No findings",
              "description" => "Parent review completed without outstanding findings.",
              "finding_key" => "completed-no-findings"
            }
          }
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
            File.join(dir, "project.yaml"),
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
      child = task_repository.fetch("Sample#5101")
      transitions = read_fake_kanban_transitions(fake_cli.fetch(:transitions_path))
      comments = read_fake_kanban_comments(fake_cli.fetch(:comments_path))
      events = read_fake_kanban_events(fake_cli.fetch(:events_path))

      expect(out.string).to include("executed 4 task(s); idle=false stop_reason=max_steps")
      expect(out.string).to include(
        "steps=Sample#5101:verification,Sample#5101:merge,Sample#5100:review,Sample#5100:verification"
      )
      expect(parent.kind).to eq(:parent)
      expect(parent.child_refs).to eq(["Sample#5101"])
      expect(parent.status).to eq(:merging)
      expect(child.status).to eq(:done)
      expect(transitions.map { |item| item.fetch("argv").last }).to include("Inspection", "Merging", "In review")
      expect(comments.fetch("5101").size).to eq(1)
      expect(events.fetch("5101").map { |item| item.fetch("kind") }).to eq(
        %w[task_started task_started task_completed]
      )
      expect(comments.fetch("5100").size).to be >= 2
    end
  end

  def seed_context(dir)
    FileUtils.mkdir_p(File.join(dir, "presets"))
    write_project_yaml(
      File.join(dir, "project.yaml"),
      merge_target_ref: "refs/heads/main"
    )
  end
end
