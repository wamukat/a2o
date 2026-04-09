# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Application::RepairRuns do
  it "reports and repairs stale shot locks and stale current runs" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::InMemoryTaskRepository.new
      run_repository = A3::Infra::InMemoryRunRepository.new

      task_repository.save(
        A3::Domain::Task.new(ref: "Portal#1", kind: :single, edit_scope: [:repo_alpha], status: :in_progress, current_run_ref: "missing-run")
      )
      File.write(File.join(dir, "scheduler-shot.lock"), "999999")

      use_case = described_class.new(
        task_repository: task_repository,
        run_repository: run_repository,
        storage_dir: dir
      )

      dry_run = use_case.call(apply: false)
      expect(dry_run.dry_run).to eq(true)
      expect(dry_run.actions.map(&:kind)).to contain_exactly(:stale_shot_lock, :stale_task_missing_run)
      expect(File.exist?(File.join(dir, "scheduler-shot.lock"))).to eq(true)
      expect(task_repository.fetch("Portal#1").current_run_ref).to eq("missing-run")

      applied = use_case.call(apply: true)
      expect(applied.dry_run).to eq(false)
      expect(applied.actions.map(&:kind)).to contain_exactly(:stale_shot_lock, :stale_task_missing_run)
      expect(File.exist?(File.join(dir, "scheduler-shot.lock"))).to eq(false)
      expect(task_repository.fetch("Portal#1").current_run_ref).to be_nil
      expect(task_repository.fetch("Portal#1").status).to eq(:in_progress)
    end
  end

  it "repairs non-terminal current runs whose workspace root is missing" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::InMemoryTaskRepository.new
      run_repository = A3::Infra::InMemoryRunRepository.new

      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-stale",
          task_ref: "Portal#3179",
          phase: :review,
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.runtime_integration_record(task_ref: "Portal#3179", ref: "refs/heads/a3/parent/Portal-3179"),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: %i[repo_alpha repo_beta], verification_scope: %i[repo_alpha repo_beta], ownership_scope: :parent),
          artifact_owner: A3::Domain::ArtifactOwner.new(owner_ref: "Portal#3179", owner_scope: :parent, snapshot_version: "refs/heads/a3/parent/Portal-3179")
        )
      )
      task_repository.save(
        A3::Domain::Task.new(
          ref: "Portal#3179",
          kind: :parent,
          edit_scope: %i[repo_alpha repo_beta],
          verification_scope: %i[repo_alpha repo_beta],
          status: :in_review,
          current_run_ref: "run-stale"
        )
      )

      use_case = described_class.new(
        task_repository: task_repository,
        run_repository: run_repository,
        storage_dir: dir
      )

      dry_run = use_case.call(apply: false)
      expect(dry_run.actions.map(&:kind)).to contain_exactly(:stale_task_missing_workspace)
      expect(task_repository.fetch("Portal#3179").current_run_ref).to eq("run-stale")

      applied = use_case.call(apply: true)
      expect(applied.actions.map(&:kind)).to contain_exactly(:stale_task_missing_workspace)
      expect(task_repository.fetch("Portal#3179").current_run_ref).to be_nil
      expect(task_repository.fetch("Portal#3179").status).to eq(:in_review)
    end
  end

  it "repairs non-terminal current runs when the active shot is gone" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::InMemoryTaskRepository.new
      run_repository = A3::Infra::InMemoryRunRepository.new

      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-stale",
          task_ref: "Portal#3153",
          phase: :implementation,
          workspace_kind: :ticket_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.ticket_branch_head(task_ref: "Portal#3153", ref: "refs/heads/a3/work/Portal-3153"),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: [:repo_alpha], verification_scope: [:repo_alpha], ownership_scope: :task),
          artifact_owner: A3::Domain::ArtifactOwner.new(owner_ref: "Portal#3153", owner_scope: :task, snapshot_version: "refs/heads/a3/work/Portal-3153")
        )
      )
      task_repository.save(
        A3::Domain::Task.new(
          ref: "Portal#3153",
          kind: :single,
          edit_scope: [:repo_alpha],
          status: :in_progress,
          current_run_ref: "run-stale"
        )
      )

      FileUtils.mkdir_p(File.join(dir, "workspaces", "Portal-3153", "ticket_workspace"))

      use_case = described_class.new(
        task_repository: task_repository,
        run_repository: run_repository,
        storage_dir: dir
      )

      dry_run = use_case.call(apply: false)
      expect(dry_run.actions.map(&:kind)).to contain_exactly(:stale_task_missing_process)
      expect(task_repository.fetch("Portal#3153").current_run_ref).to eq("run-stale")

      applied = use_case.call(apply: true)
      expect(applied.actions.map(&:kind)).to contain_exactly(:stale_task_missing_process)
      expect(task_repository.fetch("Portal#3153").current_run_ref).to be_nil
      expect(task_repository.fetch("Portal#3153").status).to eq(:in_progress)
    end
  end

  it "does not repair non-terminal runs while a direct execute-until-idle process is alive" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::InMemoryTaskRepository.new
      run_repository = A3::Infra::InMemoryRunRepository.new

      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-direct",
          task_ref: "Portal#2",
          phase: :verification,
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.runtime_integration_record(task_ref: "Portal#2", ref: "refs/heads/a3/work/Portal-2"),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: [:repo_beta], verification_scope: [:repo_beta], ownership_scope: :task),
          artifact_owner: A3::Domain::ArtifactOwner.new(owner_ref: "Portal#2", owner_scope: :task, snapshot_version: "refs/heads/a3/work/Portal-2")
        )
      )
      task_repository.save(
        A3::Domain::Task.new(
          ref: "Portal#2",
          kind: :single,
          edit_scope: [:repo_beta],
          verification_scope: [:repo_beta],
          status: :inspection,
          current_run_ref: "run-direct"
        )
      )

      FileUtils.mkdir_p(File.join(dir, "workspaces", "Portal-2", "runtime_workspace"))
      probe = instance_double(A3::Application::ExecutionProcessProbe, active_execute_until_idle?: true)

      use_case = described_class.new(
        task_repository: task_repository,
        run_repository: run_repository,
        storage_dir: dir,
        execution_process_probe: probe
      )

      dry_run = use_case.call(apply: false)
      expect(dry_run.actions).to eq([])
      expect(task_repository.fetch("Portal#2").current_run_ref).to eq("run-direct")
    end
  end
end
