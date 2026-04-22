# frozen_string_literal: true

require "json"
require "tmpdir"
require "yaml"

RSpec.describe A3::CLI do
  let(:worker_gateway) { instance_double("WorkerGateway") }
  let(:command_runner) { instance_double(A3::Infra::LocalCommandRunner) }

  before do
    allow(worker_gateway).to receive(:agent_owned_publication?).and_return(true)
  end

  it "runs implementation worker end-to-end through sqlite backend" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      seed_context(dir)
      fake_cli = create_fake_kanban_cli(
        dir,
        snapshots: [
          {
            "id" => 3025,
            "ref" => "A3-v2#3025",
            "title" => "Implementation task",
            "description" => "Run implementation worker.",
            "status" => "In progress",
            "labels" => ["repo:alpha"]
          }
        ]
      )
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      run_repository = A3::Infra::SqliteRunRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: %i[repo_alpha repo_beta],
          status: :in_progress,
          current_run_ref: "run-worker-1",
          parent_ref: "A3-v2#3022",
          external_task_id: 3025
        )
      )
      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-worker-1",
          task_ref: "A3-v2#3025",
          phase: :implementation,
          workspace_kind: :ticket_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :ticket_workspace,
            source_type: :branch_head,
            ref: "refs/heads/a2o/work/3025",
            task_ref: "A3-v2#3025"
          ),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(
            edit_scope: [:repo_alpha],
            verification_scope: %i[repo_alpha repo_beta],
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
      allow(worker_gateway).to receive(:run).and_return(
        A3::Application::ExecutionResult.new(success: true, summary: "implementation completed")
      )

      out = StringIO.new
      with_env(fake_cli.fetch(:env)) do
        described_class.start(
          [
            "run-worker-phase",
            "A3-v2#3025",
            "run-worker-1",
            File.join(dir, "project.yaml"),
            "--storage-backend", "sqlite",
            "--storage-dir", dir,
            *repo_source_args(repo_sources),
            "--preset-dir", File.join(dir, "presets"),
            "--kanban-command", "ruby",
            "--kanban-command-arg", fake_cli.fetch(:script_path),
            "--kanban-project", "A3-v2",
            "--kanban-repo-label", "repo:alpha=repo_alpha",
            "--kanban-working-dir", dir
          ],
          out: out,
          worker_gateway: worker_gateway
        )
      end

      expect(out.string).to include("worker phase completed run-worker-1")
      expect(task_repository.fetch("A3-v2#3025").status).to eq(:verifying)
    end
  end

  it "rejects child review worker through sqlite backend" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      seed_context(dir)
      fake_cli = create_fake_kanban_cli(
        dir,
        snapshots: [
          {
            "id" => 3026,
            "ref" => "A3-v2#3026",
            "title" => "Review task",
            "description" => "Run review worker.",
            "status" => "In review",
            "labels" => ["repo:alpha"]
          }
        ]
      )
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      run_repository = A3::Infra::SqliteRunRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3026",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: %i[repo_alpha repo_beta],
          status: :in_review,
          current_run_ref: "run-review-1",
          parent_ref: "A3-v2#3022",
          external_task_id: 3026
        )
      )
      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-review-1",
          task_ref: "A3-v2#3026",
          phase: :review,
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :runtime_workspace,
            source_type: :integration_record,
            ref: "refs/heads/a2o/work/3026",
            task_ref: "A3-v2#3026"
          ),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(
            edit_scope: [:repo_alpha],
            verification_scope: %i[repo_alpha repo_beta],
            ownership_scope: :task
          ),
          review_target: A3::Domain::ReviewTarget.new(
            base_commit: "base789",
            head_commit: "head999",
            task_ref: "A3-v2#3026",
            phase_ref: :review
          ),
          artifact_owner: A3::Domain::ArtifactOwner.new(
            owner_ref: "A3-v2#3022",
            owner_scope: :task,
            snapshot_version: "head999"
          )
        )
      )
      out = StringIO.new
      allow(worker_gateway).to receive(:run)
      expect do
        with_env(fake_cli.fetch(:env)) do
          described_class.start(
            [
              "run-worker-phase",
              "A3-v2#3026",
              "run-review-1",
              File.join(dir, "project.yaml"),
              "--storage-backend", "sqlite",
              "--storage-dir", dir,
              *repo_source_args(repo_sources),
              "--preset-dir", File.join(dir, "presets"),
              "--kanban-command", "ruby",
              "--kanban-command-arg", fake_cli.fetch(:script_path),
              "--kanban-project", "A3-v2",
              "--kanban-repo-label", "repo:alpha=repo_alpha",
              "--kanban-working-dir", dir
            ],
            out: out,
            worker_gateway: worker_gateway
          )
        end
      end.to raise_error(A3::Domain::InvalidPhaseError, "Unsupported phase review for child")

      expect(out.string).to eq("")
      expect(task_repository.fetch("A3-v2#3026").status).to eq(:in_review)
      expect(worker_gateway).not_to have_received(:run)
    end
  end

  it "uses an explicit local worker gateway and blocks engine-side publication after passing worker request env" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      seed_context(dir)
      fake_cli = create_fake_kanban_cli(
        dir,
        snapshots: [
          {
            "id" => 3027,
            "ref" => "A3-v2#3027",
            "title" => "Default gateway task",
            "description" => "Run default gateway worker.",
            "status" => "In progress",
            "labels" => ["repo:alpha"]
          }
        ]
      )
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      run_repository = A3::Infra::SqliteRunRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3027",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: %i[repo_alpha repo_beta],
          status: :in_progress,
          current_run_ref: "run-default-gateway-1",
          parent_ref: "A3-v2#3022",
          external_task_id: 3027
        )
      )
      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-default-gateway-1",
          task_ref: "A3-v2#3027",
          phase: :implementation,
          workspace_kind: :ticket_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :ticket_workspace,
            source_type: :branch_head,
            ref: "refs/heads/a2o/work/3027",
            task_ref: "A3-v2#3027"
          ),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(
            edit_scope: [:repo_alpha],
            verification_scope: %i[repo_alpha repo_beta],
            ownership_scope: :task
          ),
          review_target: A3::Domain::ReviewTarget.new(
            base_commit: "base3027",
            head_commit: "head3027",
            task_ref: "A3-v2#3027",
            phase_ref: :review
          ),
          artifact_owner: A3::Domain::ArtifactOwner.new(
            owner_ref: "A3-v2#3022",
            owner_scope: :task,
            snapshot_version: "head3027"
          )
        )
      )

      allow(command_runner).to receive(:run).with(
        ["skills/implementation/base.md"],
        workspace: an_instance_of(A3::Domain::PreparedWorkspace),
        env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT")
      ) do |_commands, workspace:, env:|
        request_path = Pathname(env.fetch("A2O_WORKER_REQUEST_PATH"))
        expect(request_path).to eq(workspace.root_path.join(".a2o", "worker-request.json"))
        expect(request_path).to exist

        request = JSON.parse(request_path.read)
        expect(request).to include(
          "task_ref" => "A3-v2#3027",
          "run_ref" => "run-default-gateway-1",
          "phase" => "implementation",
          "skill" => "skills/implementation/base.md"
        )

        A3::Application::ExecutionResult.new(success: true, summary: "implementation completed")
      end

      out = StringIO.new
      with_env(fake_cli.fetch(:env)) do
        described_class.start(
          [
            "run-worker-phase",
            "A3-v2#3027",
            "run-default-gateway-1",
            File.join(dir, "project.yaml"),
            "--storage-backend", "sqlite",
            "--storage-dir", dir,
            *repo_source_args(repo_sources),
            "--preset-dir", File.join(dir, "presets"),
            "--kanban-command", "ruby",
            "--kanban-command-arg", fake_cli.fetch(:script_path),
            "--kanban-project", "A3-v2",
            "--kanban-repo-label", "repo:alpha=repo_alpha",
            "--kanban-working-dir", dir,
            "--worker-gateway", "local"
          ],
          out: out,
          command_runner: command_runner
        )
      end

      expect(command_runner).to have_received(:run)
      expect(out.string).to include("worker phase completed run-default-gateway-1 with outcome blocked")
      expect(task_repository.fetch("A3-v2#3027").status).to eq(:blocked)
    end
  end

  def seed_context(dir)
    FileUtils.mkdir_p(File.join(dir, "presets"))
    write_project_yaml(
      File.join(dir, "project.yaml"),
      merge_target_ref: "refs/heads/a2o/parent/default"
    )
  end
end
