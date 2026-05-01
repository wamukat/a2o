# frozen_string_literal: true

require "timeout"

RSpec.describe "bounded parallel scheduler integration" do
  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:run_repository) { A3::Infra::InMemoryRunRepository.new }
  let(:claim_repository) do
    counter = 0
    A3::Infra::InMemorySchedulerTaskClaimRepository.new(
      claim_ref_generator: -> { counter += 1; "claim-#{counter}" }
    )
  end
  let(:sync_external_tasks) { instance_double(A3::Application::SyncExternalTasks, call: nil) }
  let(:start_run) { instance_double(A3::Application::StartRun) }
  let(:run_worker_phase) { instance_double(A3::Application::RunWorkerPhase) }
  let(:run_verification) { instance_double(A3::Application::RunVerification) }
  let(:run_merge) { instance_double(A3::Application::RunMerge) }
  let(:project_context) do
    A3::Domain::ProjectContext.new(
      surface: A3::Domain::ProjectSurface.new(
        implementation_skill: "skills/implementation/base.md",
        review_skill: "skills/review/base.md",
        verification_commands: ["commands/verify-all"],
        remediation_commands: ["commands/apply-remediation"],
        scheduler_config: A3::Domain::ProjectSchedulerConfig.new(max_parallel_tasks: 2),
        workspace_hook: "hooks/prepare-runtime.sh"
      ),
      merge_config: A3::Domain::MergeConfig.new(
        target: :merge_to_parent,
        policy: :ff_only
      )
    )
  end

  subject(:execute_batch) do
    plan_next = A3::Application::PlanNextRunnableTask.new(task_repository: task_repository)
    schedule_next_run = A3::Application::ScheduleNextRun.new(
      plan_next_runnable_task: plan_next,
      start_run: start_run,
      build_scope_snapshot: A3::Application::BuildScopeSnapshot.new,
      build_artifact_owner: A3::Application::BuildArtifactOwner.new,
      run_repository: run_repository,
      integration_ref_readiness_checker: instance_double(
        A3::Infra::IntegrationRefReadinessChecker,
        check: A3::Infra::IntegrationRefReadinessChecker::Result.new(ready: true, missing_slots: [], ref: "refs/heads/a2o/parent/A2O-1")
      )
    )
    A3::Application::ExecuteRunnableTaskBatch.new(
      plan_runnable_task_batch: A3::Application::PlanRunnableTaskBatch.new(
        task_repository: task_repository,
        run_repository: run_repository,
        task_claim_repository: claim_repository,
        sync_external_tasks: sync_external_tasks
      ),
      schedule_next_run: schedule_next_run,
      task_claim_repository: claim_repository,
      run_repository: run_repository,
      run_worker_phase: run_worker_phase,
      run_verification: run_verification,
      run_merge: run_merge,
      claimed_by: "integration-test"
    )
  end

  before do
    allow(start_run).to receive(:call) do |task_ref:, phase:, **_kwargs|
      run_ref = "run-#{task_ref.delete_prefix('A2O#')}"
      task = task_repository.fetch(task_ref).start_run(run_ref, phase: phase)
      run = run_record(ref: run_ref, task_ref: task_ref, phase: phase)
      task_repository.save(task)
      run_repository.save(run)
      A3::Application::StartRun::Result.new(task: task, run: run, workspace: nil)
    end
    allow(run_worker_phase).to receive(:call) do |task_ref:, run_ref:, project_context:|
      run_repository.save(run_repository.fetch(run_ref).complete(outcome: :completed))
      "completed #{task_ref}"
    end
  end

  it "executes independent tasks in the same bounded batch and releases terminal claims" do
    save_task(ref: "A2O#501", priority: 3)
    save_task(ref: "A2O#502", priority: 2)
    started = Queue.new
    release = Queue.new
    allow(run_worker_phase).to receive(:call) do |task_ref:, run_ref:, project_context:|
      started << task_ref
      release.pop
      run_repository.save(run_repository.fetch(run_ref).complete(outcome: :completed))
      "completed #{task_ref}"
    end

    result_thread = Thread.new { execute_batch.call(project_context: project_context, max_steps: 2) }
    started_refs = Timeout.timeout(2) { 2.times.map { started.pop } }
    2.times { release << true }
    result = result_thread.value

    expect(started_refs).to contain_exactly("A2O#501", "A2O#502")
    expect(result.executions.map { |execution| execution.task.ref }).to contain_exactly("A2O#501", "A2O#502")
    expect(start_run).to have_received(:call).twice
    expect(run_worker_phase).to have_received(:call).twice
    expect(claim_repository.active_claims).to be_empty
  end

  it "honors a single-slot scheduler configuration" do
    save_task(ref: "A2O#503", priority: 3)
    save_task(ref: "A2O#504", priority: 2)

    result = execute_batch.call(project_context: project_context_for(max_parallel_tasks: 1), max_steps: 2)

    expect(result.executions.map { |execution| execution.task.ref }).to eq(["A2O#503"])
    expect(start_run).to have_received(:call).once
    expect(claim_repository.active_claims).to be_empty
  end

  it "excludes same-parent siblings while still filling a free slot with an independent task" do
    parent = save_task(ref: "A2O#600", kind: :parent, child_refs: %w[A2O#601 A2O#602], priority: 4)
    save_task(ref: "A2O#601", kind: :child, parent_ref: parent.ref, priority: 3)
    save_task(ref: "A2O#602", kind: :child, parent_ref: parent.ref, priority: 2)
    save_task(ref: "A2O#700", priority: 1)

    result = execute_batch.call(project_context: project_context, max_steps: 2)

    expect(result.executions.map { |execution| execution.task.ref }).to contain_exactly("A2O#601", "A2O#700")
    expect(result.batch_plan.skipped_conflicts.map(&:task_ref)).to include("A2O#602")
  end

  def save_task(ref:, kind: :single, parent_ref: nil, child_refs: [], priority: 0, status: :todo)
    task = A3::Domain::Task.new(
      ref: ref,
      kind: kind,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: status,
      parent_ref: parent_ref,
      child_refs: child_refs,
      priority: priority
    )
    task_repository.save(task)
    task
  end

  def project_context_for(max_parallel_tasks:)
    A3::Domain::ProjectContext.new(
      surface: A3::Domain::ProjectSurface.new(
        implementation_skill: "skills/implementation/base.md",
        review_skill: "skills/review/base.md",
        verification_commands: ["commands/verify-all"],
        remediation_commands: ["commands/apply-remediation"],
        scheduler_config: A3::Domain::ProjectSchedulerConfig.new(max_parallel_tasks: max_parallel_tasks),
        workspace_hook: "hooks/prepare-runtime.sh"
      ),
      merge_config: A3::Domain::MergeConfig.new(
        target: :merge_to_parent,
        policy: :ff_only
      )
    )
  end

  def run_record(ref:, task_ref:, phase:)
    A3::Domain::Run.new(
      ref: ref,
      task_ref: task_ref,
      phase: phase,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.ticket_branch_head(task_ref: task_ref, ref: "refs/heads/a2o/work/#{task_ref.tr('#', '-')}"),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: [:repo_alpha], verification_scope: [:repo_alpha], ownership_scope: :task),
      artifact_owner: A3::Domain::ArtifactOwner.new(owner_ref: task_ref, owner_scope: :task, snapshot_version: "refs/heads/a2o/work/#{task_ref.tr('#', '-')}")
    )
  end
end
