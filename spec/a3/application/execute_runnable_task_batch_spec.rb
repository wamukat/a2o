# frozen_string_literal: true

RSpec.describe A3::Application::ExecuteRunnableTaskBatch do
  let(:plan_runnable_task_batch) { instance_double(A3::Application::PlanRunnableTaskBatch) }
  let(:schedule_next_run) { instance_double(A3::Application::ScheduleNextRun) }
  let(:task_claim_repository) do
    counter = 0
    A3::Infra::InMemorySchedulerTaskClaimRepository.new(
      claim_ref_generator: -> { counter += 1; "claim-#{counter}" }
    )
  end
  let(:run_repository) { A3::Infra::InMemoryRunRepository.new }
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

  subject(:use_case) do
    described_class.new(
      plan_runnable_task_batch: plan_runnable_task_batch,
      schedule_next_run: schedule_next_run,
      task_claim_repository: task_claim_repository,
      run_repository: run_repository,
      run_worker_phase: run_worker_phase,
      run_verification: run_verification,
      run_merge: run_merge,
      claimed_by: "scheduler-test"
    )
  end

  it "plans with the project parallelism and executes selected candidates concurrently" do
    task_a = task(ref: "A2O#501", priority: 2)
    task_b = task(ref: "A2O#502", priority: 1)
    plan = plan_result(task_a, task_b)
    allow(plan_runnable_task_batch).to receive(:call).with(max_parallel_tasks: 2).and_return(plan)
    allow(schedule_next_run).to receive(:schedulable_candidate?).and_return(true)
    allow(schedule_next_run).to receive(:schedule_candidate).and_return(
      scheduled(task: task_a, run_ref: "run-a"),
      scheduled(task: task_b, run_ref: "run-b")
    )

    started = Queue.new
    release = Queue.new
    allow(run_worker_phase).to receive(:call) do |task_ref:, run_ref:, project_context:|
      started << task_ref
      release.pop
      run_repository.save(run_double(ref: run_ref, task_ref: task_ref, terminal: true))
      "completed-#{task_ref}"
    end

    result_thread = Thread.new { use_case.call(project_context: project_context, max_steps: 2) }
    started_refs = 2.times.map { started.pop }
    expect(started_refs).to contain_exactly("A2O#501", "A2O#502")

    2.times { release << true }
    result = result_thread.value

    expect(result.executions.map(&:task).map(&:ref)).to contain_exactly("A2O#501", "A2O#502")
    expect(result).not_to be_empty
    expect(task_claim_repository.active_claims).to be_empty
  end

  it "keeps a claim active when the run remains non-terminal" do
    task_a = task(ref: "A2O#503")
    allow(plan_runnable_task_batch).to receive(:call).with(max_parallel_tasks: 2).and_return(plan_result(task_a))
    allow(schedule_next_run).to receive(:schedulable_candidate?).and_return(true)
    allow(schedule_next_run).to receive(:schedule_candidate).and_return(scheduled(task: task_a, run_ref: "run-a"))
    run_repository.save(run_double(ref: "run-a", task_ref: task_a.ref, terminal: false))
    allow(run_worker_phase).to receive(:call).and_return(:worker_result)

    result = use_case.call(project_context: project_context, max_steps: 1)

    expect(result.executions.size).to eq(1)
    expect(task_claim_repository.active_claims.map(&:task_ref)).to eq(["A2O#503"])
  end

  it "preserves empty batch planning state for the scheduler" do
    empty_plan = A3::Application::PlanRunnableTaskBatch::Result.new(
      candidates: [],
      skipped_conflicts: [],
      assessments: [],
      active_slot_count: 0,
      available_slot_count: 2
    )
    allow(plan_runnable_task_batch).to receive(:call).with(max_parallel_tasks: 2).and_return(empty_plan)

    result = use_case.call(project_context: project_context, max_steps: 2)

    expect(result.executions).to eq([])
    expect(result).to be_idle
  end

  it "waits for all started workers before surfacing a worker failure" do
    task_a = task(ref: "A2O#504")
    task_b = task(ref: "A2O#505")
    allow(plan_runnable_task_batch).to receive(:call).with(max_parallel_tasks: 2).and_return(plan_result(task_a, task_b))
    allow(schedule_next_run).to receive(:schedulable_candidate?).and_return(true)
    allow(schedule_next_run).to receive(:schedule_candidate).and_return(
      scheduled(task: task_a, run_ref: "run-a"),
      scheduled(task: task_b, run_ref: "run-b")
    )

    slow_worker_finished = Queue.new
    allow(run_worker_phase).to receive(:call) do |task_ref:, run_ref:, project_context:|
      if task_ref == "A2O#504"
        raise "worker failed"
      end

      sleep 0.05
      run_repository.save(run_double(ref: run_ref, task_ref: task_ref, terminal: true))
      slow_worker_finished << task_ref
      :slow_worker_result
    end

    expect { use_case.call(project_context: project_context, max_steps: 2) }
      .to raise_error(RuntimeError, "worker failed")
    expect(slow_worker_finished.pop).to eq("A2O#505")
    expect(task_claim_repository.active_claims.map(&:task_ref)).to eq(["A2O#504"])
  end

  def task(ref:, priority: 0)
    A3::Domain::Task.new(
      ref: ref,
      kind: :single,
      edit_scope: [:repo_alpha],
      status: :todo,
      priority: priority
    )
  end

  def plan_result(*tasks)
    candidates = tasks.map do |task|
      assessment = A3::Domain::RunnableTaskAssessment.evaluate(task: task, tasks: tasks)
      A3::Application::PlanRunnableTaskBatch::Candidate.new(
        task: task,
        phase: assessment.phase,
        assessment: assessment,
        conflict_keys: A3::Domain::SchedulerConflictKeys.for_task(task: task, tasks: tasks)
      )
    end
    A3::Application::PlanRunnableTaskBatch::Result.new(
      candidates: candidates,
      skipped_conflicts: [],
      assessments: candidates.map(&:assessment),
      active_slot_count: 0,
      available_slot_count: 2
    )
  end

  def scheduled(task:, run_ref:)
    run = run_double(ref: run_ref, task_ref: task.ref, terminal: false)
    run_repository.save(run)
    A3::Application::ScheduleNextRun::Result.new(
      task: task,
      phase: :implementation,
      started_run: A3::Application::StartRun::Result.new(task: task, run: run, workspace: nil)
    )
  end

  def run_double(ref:, task_ref:, terminal:)
    instance_double(A3::Domain::Run, ref: ref, task_ref: task_ref, terminal?: terminal)
  end
end
