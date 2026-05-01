# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Application::RepairRuns do
  it "reports and repairs stale shot locks and stale current runs" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::InMemoryTaskRepository.new
      run_repository = A3::Infra::InMemoryRunRepository.new

      task_repository.save(
        A3::Domain::Task.new(ref: "Sample#1", kind: :single, edit_scope: [:repo_alpha], status: :in_progress, current_run_ref: "missing-run")
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
      expect(task_repository.fetch("Sample#1").current_run_ref).to eq("missing-run")

      applied = use_case.call(apply: true)
      expect(applied.dry_run).to eq(false)
      expect(applied.actions.map(&:kind)).to contain_exactly(:stale_shot_lock, :stale_task_missing_run)
      expect(File.exist?(File.join(dir, "scheduler-shot.lock"))).to eq(false)
      expect(task_repository.fetch("Sample#1").current_run_ref).to be_nil
      expect(task_repository.fetch("Sample#1").status).to eq(:in_progress)
    end
  end

  it "repairs non-terminal current runs whose workspace root is missing" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::InMemoryTaskRepository.new
      run_repository = A3::Infra::InMemoryRunRepository.new

      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-stale",
          task_ref: "Sample#3179",
          phase: :review,
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.runtime_integration_record(task_ref: "Sample#3179", ref: "refs/heads/a2o/parent/Sample-3179"),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: %i[repo_alpha repo_beta], verification_scope: %i[repo_alpha repo_beta], ownership_scope: :parent),
          artifact_owner: A3::Domain::ArtifactOwner.new(owner_ref: "Sample#3179", owner_scope: :parent, snapshot_version: "refs/heads/a2o/parent/Sample-3179")
        )
      )
      task_repository.save(
        A3::Domain::Task.new(
          ref: "Sample#3179",
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
      expect(task_repository.fetch("Sample#3179").current_run_ref).to eq("run-stale")

      applied = use_case.call(apply: true)
      expect(applied.actions.map(&:kind)).to contain_exactly(:stale_task_missing_workspace)
      expect(task_repository.fetch("Sample#3179").current_run_ref).to be_nil
      expect(task_repository.fetch("Sample#3179").status).to eq(:in_review)
    end
  end

  it "repairs non-terminal current runs when the active shot is gone" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::InMemoryTaskRepository.new
      run_repository = A3::Infra::InMemoryRunRepository.new

      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-stale",
          task_ref: "Sample#3153",
          phase: :implementation,
          workspace_kind: :ticket_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.ticket_branch_head(task_ref: "Sample#3153", ref: "refs/heads/a2o/work/Sample-3153"),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: [:repo_alpha], verification_scope: [:repo_alpha], ownership_scope: :task),
          artifact_owner: A3::Domain::ArtifactOwner.new(owner_ref: "Sample#3153", owner_scope: :task, snapshot_version: "refs/heads/a2o/work/Sample-3153")
        )
      )
      task_repository.save(
        A3::Domain::Task.new(
          ref: "Sample#3153",
          kind: :single,
          edit_scope: [:repo_alpha],
          status: :in_progress,
          current_run_ref: "run-stale"
        )
      )

      FileUtils.mkdir_p(File.join(dir, "workspaces", "Sample-3153", "ticket_workspace"))

      use_case = described_class.new(
        task_repository: task_repository,
        run_repository: run_repository,
        storage_dir: dir
      )

      dry_run = use_case.call(apply: false)
      expect(dry_run.actions.map(&:kind)).to contain_exactly(:stale_task_missing_process)
      expect(task_repository.fetch("Sample#3153").current_run_ref).to eq("run-stale")

      applied = use_case.call(apply: true)
      expect(applied.actions.map(&:kind)).to contain_exactly(:stale_task_missing_process)
      expect(task_repository.fetch("Sample#3153").current_run_ref).to be_nil
      expect(task_repository.fetch("Sample#3153").status).to eq(:in_progress)
    end
  end

  it "marks claimed agent jobs stale when repairing a run whose runtime process is gone" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::InMemoryTaskRepository.new
      run_repository = A3::Infra::InMemoryRunRepository.new
      agent_job_store = A3::Infra::JsonAgentJobStore.new(File.join(dir, "agent_jobs.json"))

      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-stale",
          task_ref: "Sample#336",
          phase: :verification,
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.runtime_integration_record(task_ref: "Sample#336", ref: "refs/heads/a2o/work/Sample-336"),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: [:repo_alpha], verification_scope: [:repo_alpha], ownership_scope: :task),
          artifact_owner: A3::Domain::ArtifactOwner.new(owner_ref: "Sample#336", owner_scope: :task, snapshot_version: "refs/heads/a2o/work/Sample-336")
        )
      )
      task_repository.save(
        A3::Domain::Task.new(
          ref: "Sample#336",
          kind: :single,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha],
          status: :inspection,
          current_run_ref: "run-stale"
        )
      )
      FileUtils.mkdir_p(File.join(dir, "workspaces", "Sample-336", "runtime_workspace"))
      agent_job_store.enqueue(agent_job_request("command-run-stale-verification", task_ref: "Sample#336", run_ref: "run-stale"))
      agent_job_store.claim_next(agent_name: "host-local-agent", claimed_at: "2026-04-11T08:00:00Z")

      use_case = described_class.new(
        task_repository: task_repository,
        run_repository: run_repository,
        storage_dir: dir,
        agent_job_store: agent_job_store
      )

      dry_run = use_case.call(apply: false)
      expect(dry_run.actions.map(&:kind)).to contain_exactly(:stale_task_claimed_agent_job)
      expect(agent_job_store.fetch("command-run-stale-verification").state).to eq(:claimed)

      applied = use_case.call(apply: true)
      expect(applied.actions.map(&:kind)).to contain_exactly(:stale_task_claimed_agent_job)
      expect(task_repository.fetch("Sample#336").current_run_ref).to be_nil
      expect(agent_job_store.fetch("command-run-stale-verification")).to have_attributes(
        state: :stale,
        stale_reason: "runtime process stopped before agent job result was recorded"
      )
    end
  end

  it "repairs tasks pointing at corrupt JSON run records" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::InMemoryTaskRepository.new
      run_repository = A3::Infra::JsonRunRepository.new(File.join(dir, "runs.json"))
      File.write(
        File.join(dir, "runs.json"),
        JSON.pretty_generate("run-corrupt" => ["not", "a", "hash"])
      )

      task_repository.save(
        A3::Domain::Task.new(
          ref: "Sample#3153",
          kind: :single,
          edit_scope: [:repo_alpha],
          status: :in_progress,
          current_run_ref: "run-corrupt"
        )
      )

      use_case = described_class.new(
        task_repository: task_repository,
        run_repository: run_repository,
        storage_dir: dir
      )

      dry_run = use_case.call(apply: false)
      expect(dry_run.actions.map(&:kind)).to contain_exactly(:corrupt_run_record)
      expect(task_repository.fetch("Sample#3153").current_run_ref).to eq("run-corrupt")

      applied = use_case.call(apply: true)
      expect(applied.actions.map(&:kind)).to contain_exactly(:corrupt_run_record)
      expect(task_repository.fetch("Sample#3153").current_run_ref).to be_nil
      expect(task_repository.fetch("Sample#3153").status).to eq(:in_progress)
    end
  end

  it "does not repair non-terminal runs while a direct execute-until-idle process is alive" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::InMemoryTaskRepository.new
      run_repository = A3::Infra::InMemoryRunRepository.new

      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-direct",
          task_ref: "Sample#2",
          phase: :verification,
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.runtime_integration_record(task_ref: "Sample#2", ref: "refs/heads/a2o/work/Sample-2"),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: [:repo_beta], verification_scope: [:repo_beta], ownership_scope: :task),
          artifact_owner: A3::Domain::ArtifactOwner.new(owner_ref: "Sample#2", owner_scope: :task, snapshot_version: "refs/heads/a2o/work/Sample-2")
        )
      )
      task_repository.save(
        A3::Domain::Task.new(
          ref: "Sample#2",
          kind: :single,
          edit_scope: [:repo_beta],
          verification_scope: [:repo_beta],
          status: :inspection,
          current_run_ref: "run-direct"
        )
      )

      FileUtils.mkdir_p(File.join(dir, "workspaces", "Sample-2", "runtime_workspace"))
      probe = instance_double(A3::Application::ExecutionProcessProbe, active_execute_until_idle?: true)

      use_case = described_class.new(
        task_repository: task_repository,
        run_repository: run_repository,
        storage_dir: dir,
        execution_process_probe: probe
      )

      dry_run = use_case.call(apply: false)
      expect(dry_run.actions).to eq([])
      expect(task_repository.fetch("Sample#2").current_run_ref).to eq("run-direct")
    end
  end

  it "marks scheduler task claims stale when their linked run is no longer active" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::InMemoryTaskRepository.new
      run_repository = A3::Infra::InMemoryRunRepository.new
      task_claim_repository = A3::Infra::InMemorySchedulerTaskClaimRepository.new(claim_ref_generator: -> { "claim-stale" })
      run_repository.save(stale_run(ref: "run-terminal", task_ref: "Sample#418").complete(outcome: :completed))
      claim = task_claim_repository.claim_task(
        task_ref: "Sample#418",
        phase: :implementation,
        parent_group_key: "Sample#418",
        claimed_by: "scheduler-test",
        claimed_at: "2026-04-30T01:00:00Z"
      )
      task_claim_repository.link_run(claim_ref: claim.claim_ref, run_ref: "run-terminal")

      use_case = described_class.new(
        task_repository: task_repository,
        run_repository: run_repository,
        storage_dir: dir,
        task_claim_repository: task_claim_repository
      )

      dry_run = use_case.call(apply: false)
      expect(dry_run.actions.map(&:kind)).to contain_exactly(:stale_scheduler_task_claim)
      expect(task_claim_repository.active_claims.map(&:claim_ref)).to eq(["claim-stale"])

      applied = use_case.call(apply: true)
      expect(applied.actions.map(&:kind)).to contain_exactly(:stale_scheduler_task_claim)
      expect(task_claim_repository.active_claims).to be_empty
      expect(task_claim_repository.fetch("claim-stale").stale_reason).to eq("scheduler task claim references terminal run")
    end
  end

  it "keeps scheduler task claims active while their run workspace and runtime process are active" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::InMemoryTaskRepository.new
      run_repository = A3::Infra::InMemoryRunRepository.new
      task_claim_repository = A3::Infra::InMemorySchedulerTaskClaimRepository.new(claim_ref_generator: -> { "claim-active" })
      run_repository.save(stale_run(ref: "run-active", task_ref: "Sample#419"))
      FileUtils.mkdir_p(File.join(dir, "workspaces", "Sample-419", "ticket_workspace"))
      claim = task_claim_repository.claim_task(
        task_ref: "Sample#419",
        phase: :implementation,
        parent_group_key: "Sample#419",
        claimed_by: "scheduler-test",
        claimed_at: "2026-04-30T01:00:00Z"
      )
      task_claim_repository.link_run(claim_ref: claim.claim_ref, run_ref: "run-active")
      probe = instance_double(A3::Application::ExecutionProcessProbe, active_execute_until_idle?: true)

      use_case = described_class.new(
        task_repository: task_repository,
        run_repository: run_repository,
        storage_dir: dir,
        execution_process_probe: probe,
        task_claim_repository: task_claim_repository
      )

      dry_run = use_case.call(apply: false)
      expect(dry_run.actions).to eq([])
      expect(task_claim_repository.active_claims.map(&:claim_ref)).to eq(["claim-active"])
    end
  end

  def agent_job_request(job_id, task_ref:, run_ref:)
    A3::Domain::AgentJobRequest.new(
      job_id: job_id,
      task_ref: task_ref,
      run_ref: run_ref,
      phase: :verification,
      runtime_profile: "host-local-agent",
      source_descriptor: A3::Domain::SourceDescriptor.runtime_integration_record(task_ref: task_ref, ref: "refs/heads/a2o/work/Sample-336"),
      working_dir: "/workspace/repo-alpha",
      command: "sh",
      args: ["-lc", "task test"],
      env: {},
      timeout_seconds: 1800,
      artifact_rules: []
    )
  end

  def stale_run(ref:, task_ref:)
    A3::Domain::Run.new(
      ref: ref,
      task_ref: task_ref,
      phase: :implementation,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.ticket_branch_head(task_ref: task_ref, ref: "refs/heads/a2o/work/#{task_ref.tr("#", "-")}"),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: [:repo_alpha], verification_scope: [:repo_alpha], ownership_scope: :task),
      artifact_owner: A3::Domain::ArtifactOwner.new(owner_ref: task_ref, owner_scope: :task, snapshot_version: "refs/heads/a2o/work/#{task_ref.tr("#", "-")}")
    )
  end
end
