# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Application::ShowState do
  it "aggregates scheduler, shot, active run, queued task, and blocked task state" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::InMemoryTaskRepository.new
      run_repository = A3::Infra::InMemoryRunRepository.new
      scheduler_state_repository = A3::Infra::InMemorySchedulerStateRepository.new
      scheduler_cycle_repository = A3::Infra::InMemorySchedulerCycleRepository.new

      scheduler_state_repository.save(
        A3::Domain::SchedulerState.new(paused: false, last_stop_reason: :idle, last_executed_count: 2)
      )

      active_run = A3::Domain::Run.new(
        ref: "run-1",
        task_ref: "Portal#1",
        phase: :implementation,
        workspace_kind: :ticket_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.ticket_branch_head(task_ref: "Portal#1", ref: "refs/heads/a3/work/Portal-1"),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: [:repo_alpha], verification_scope: [:repo_alpha], ownership_scope: :repo_alpha),
        artifact_owner: A3::Domain::ArtifactOwner.new(owner_ref: "Portal#1", owner_scope: :task, snapshot_version: "refs/heads/a3/work/Portal-1")
      )
      run_repository.save(active_run)

      task_repository.save(
        A3::Domain::Task.new(ref: "Portal#1", kind: :single, edit_scope: [:repo_alpha], status: :in_progress, current_run_ref: "run-1")
      )
      task_repository.save(
        A3::Domain::Task.new(ref: "Portal#2", kind: :single, edit_scope: [:repo_alpha], status: :todo)
      )
      task_repository.save(
        A3::Domain::Task.new(ref: "Portal#3", kind: :single, edit_scope: [:repo_alpha], status: :blocked)
      )

      File.write(File.join(dir, "scheduler-shot.lock"), Process.pid.to_s)
      FileUtils.mkdir_p(File.join(dir, "workspaces", "Portal-1", "ticket_workspace"))

      result = described_class.new(
        task_repository: task_repository,
        run_repository: run_repository,
        scheduler_state_repository: scheduler_state_repository,
        scheduler_cycle_repository: scheduler_cycle_repository,
        storage_dir: dir
      ).call

      expect(result.scheduler_state.last_cycle_summary).to eq("stop_reason=idle executed_count=2")
      expect(result.shot_state.status).to eq(:active)
      expect(result.active_runs.map(&:task_ref)).to eq(["Portal#1"])
      expect(result.active_runs.first.status).to eq(:active)
      expect(result.queued_tasks.map(&:task_ref)).to eq(["Portal#2"])
      expect(result.blocked_tasks.map(&:task_ref)).to eq(["Portal#3"])
      expect(result.repairable_items).to eq([])
    end
  end

  it "marks non-terminal runs without a workspace root as repairable stale runs" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::InMemoryTaskRepository.new
      run_repository = A3::Infra::InMemoryRunRepository.new
      scheduler_state_repository = A3::Infra::InMemorySchedulerStateRepository.new
      scheduler_cycle_repository = A3::Infra::InMemorySchedulerCycleRepository.new

      scheduler_state_repository.save(
        A3::Domain::SchedulerState.new(paused: false, last_stop_reason: :idle, last_executed_count: 0)
      )

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
        A3::Domain::Task.new(ref: "Portal#3179", kind: :parent, edit_scope: %i[repo_alpha repo_beta], verification_scope: %i[repo_alpha repo_beta], status: :in_review, current_run_ref: "run-stale")
      )

      result = described_class.new(
        task_repository: task_repository,
        run_repository: run_repository,
        scheduler_state_repository: scheduler_state_repository,
        scheduler_cycle_repository: scheduler_cycle_repository,
        storage_dir: dir
      ).call

      expect(result.active_runs.map(&:task_ref)).to eq(["Portal#3179"])
      expect(result.active_runs.first.status).to eq(:stale_workspace)
      expect(result.repairable_items).to eq(["stale_run:Portal#3179"])
    end
  end

  it "marks non-terminal runs without an active shot as repairable stale runs" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::InMemoryTaskRepository.new
      run_repository = A3::Infra::InMemoryRunRepository.new
      scheduler_state_repository = A3::Infra::InMemorySchedulerStateRepository.new
      scheduler_cycle_repository = A3::Infra::InMemorySchedulerCycleRepository.new

      scheduler_state_repository.save(
        A3::Domain::SchedulerState.new(paused: false, last_stop_reason: :idle, last_executed_count: 0)
      )

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
        A3::Domain::Task.new(ref: "Portal#3153", kind: :single, edit_scope: [:repo_alpha], status: :in_progress, current_run_ref: "run-stale")
      )

      FileUtils.mkdir_p(File.join(dir, "workspaces", "Portal-3153", "ticket_workspace"))

      result = described_class.new(
        task_repository: task_repository,
        run_repository: run_repository,
        scheduler_state_repository: scheduler_state_repository,
        scheduler_cycle_repository: scheduler_cycle_repository,
        storage_dir: dir
      ).call

      expect(result.active_runs.map(&:task_ref)).to eq(["Portal#3153"])
      expect(result.active_runs.first.status).to eq(:stale_process)
      expect(result.repairable_items).to eq(["stale_run:Portal#3153"])
    end
  end

  it "treats live direct execute-until-idle processes as active without a scheduler shot lock" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::InMemoryTaskRepository.new
      run_repository = A3::Infra::InMemoryRunRepository.new
      scheduler_state_repository = A3::Infra::InMemorySchedulerStateRepository.new
      scheduler_cycle_repository = A3::Infra::InMemorySchedulerCycleRepository.new

      scheduler_state_repository.save(
        A3::Domain::SchedulerState.new(paused: false, last_stop_reason: :idle, last_executed_count: 0)
      )

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
        A3::Domain::Task.new(ref: "Portal#2", kind: :single, edit_scope: [:repo_beta], verification_scope: [:repo_beta], status: :inspection, current_run_ref: "run-direct")
      )

      FileUtils.mkdir_p(File.join(dir, "workspaces", "Portal-2", "runtime_workspace"))
      probe = instance_double(A3::Application::ExecutionProcessProbe, active_execute_until_idle?: true)

      result = described_class.new(
        task_repository: task_repository,
        run_repository: run_repository,
        scheduler_state_repository: scheduler_state_repository,
        scheduler_cycle_repository: scheduler_cycle_repository,
        storage_dir: dir,
        execution_process_probe: probe
      ).call

      expect(result.shot_state.status).to eq(:none)
      expect(result.active_runs.map(&:task_ref)).to eq(["Portal#2"])
      expect(result.active_runs.first.status).to eq(:active)
      expect(result.repairable_items).to eq([])
    end
  end

  it "canonicalizes historical child review runs to verification in operator state" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::InMemoryTaskRepository.new
      run_repository = A3::Infra::InMemoryRunRepository.new
      scheduler_state_repository = A3::Infra::InMemorySchedulerStateRepository.new
      scheduler_cycle_repository = A3::Infra::InMemorySchedulerCycleRepository.new

      scheduler_state_repository.save(
        A3::Domain::SchedulerState.new(paused: false, last_stop_reason: :idle, last_executed_count: 0)
      )

      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-legacy-review",
          task_ref: "Portal#9",
          phase: :review,
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.runtime_integration_record(task_ref: "Portal#9", ref: "refs/heads/a3/work/Portal-9"),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: [:repo_alpha], verification_scope: [:repo_alpha], ownership_scope: :task),
          artifact_owner: A3::Domain::ArtifactOwner.new(owner_ref: "Portal#9", owner_scope: :task, snapshot_version: "refs/heads/a3/work/Portal-9")
        )
      )
      task_repository.save(
        A3::Domain::Task.new(ref: "Portal#9", kind: :child, edit_scope: [:repo_alpha], verification_scope: [:repo_alpha], status: :in_review, current_run_ref: "run-legacy-review")
      )

      FileUtils.mkdir_p(File.join(dir, "workspaces", "Portal-9", "runtime_workspace"))
      File.write(File.join(dir, "scheduler-shot.lock"), Process.pid.to_s)

      result = described_class.new(
        task_repository: task_repository,
        run_repository: run_repository,
        scheduler_state_repository: scheduler_state_repository,
        scheduler_cycle_repository: scheduler_cycle_repository,
        storage_dir: dir
      ).call

      expect(result.active_runs.map(&:task_ref)).to eq(["Portal#9"])
      expect(result.active_runs.first.phase).to eq(:verification)
      expect(result.active_runs.first.status).to eq(:active)
    end
  end
end
