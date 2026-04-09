# frozen_string_literal: true

RSpec.describe A3::Application::ExecuteNextRunnableTask do
  let(:schedule_next_run) { instance_double(A3::Application::ScheduleNextRun) }
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
      schedule_next_run: schedule_next_run,
      run_worker_phase: run_worker_phase,
      run_verification: run_verification,
      run_merge: run_merge
    )
  end

  let(:task) do
    A3::Domain::Task.new(
      ref: "A3-v2#3030",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :todo
    )
  end

  let(:started_run) do
    instance_double(
      A3::Application::StartRun::Result,
      task: task,
      run: instance_double(A3::Domain::Run, ref: "run-1", phase: :implementation)
    )
  end

  it "dispatches implementation to worker phase execution" do
    allow(schedule_next_run).to receive(:call).and_return(
      A3::Application::ScheduleNextRun::Result.new(
        task: task,
        phase: :implementation,
        started_run: started_run
      )
    )
    allow(run_worker_phase).to receive(:call).with(
      task_ref: task.ref,
      run_ref: "run-1",
      project_context: project_context
    ).and_return(:worker_result)

    result = use_case.call(project_context: project_context)

    expect(result.phase).to eq(:implementation)
    expect(result.execution_result).to eq(:worker_result)
  end

  it "dispatches verification to verification execution" do
    verification_run = instance_double(A3::Application::StartRun::Result, task: task, run: instance_double(A3::Domain::Run, ref: "run-2", phase: :verification))
    allow(schedule_next_run).to receive(:call).and_return(
      A3::Application::ScheduleNextRun::Result.new(
        task: task,
        phase: :verification,
        started_run: verification_run
      )
    )
    allow(run_verification).to receive(:call).and_return(:verification_result)

    result = use_case.call(project_context: project_context)

    expect(result.phase).to eq(:verification)
    expect(result.execution_result).to eq(:verification_result)
  end

  it "dispatches review to worker phase execution" do
    review_run = instance_double(A3::Application::StartRun::Result, task: task, run: instance_double(A3::Domain::Run, ref: "run-review", phase: :review))
    allow(schedule_next_run).to receive(:call).and_return(
      A3::Application::ScheduleNextRun::Result.new(
        task: task,
        phase: :review,
        started_run: review_run
      )
    )
    allow(run_worker_phase).to receive(:call).with(
      task_ref: task.ref,
      run_ref: "run-review",
      project_context: project_context
    ).and_return(:review_result)

    result = use_case.call(project_context: project_context)

    expect(result.phase).to eq(:review)
    expect(result.execution_result).to eq(:review_result)
  end

  it "dispatches merge to merge execution" do
    merge_run = instance_double(A3::Application::StartRun::Result, task: task, run: instance_double(A3::Domain::Run, ref: "run-merge", phase: :merge))
    allow(schedule_next_run).to receive(:call).and_return(
      A3::Application::ScheduleNextRun::Result.new(
        task: task,
        phase: :merge,
        started_run: merge_run
      )
    )
    allow(run_merge).to receive(:call).with(
      task_ref: task.ref,
      run_ref: "run-merge",
      project_context: project_context
    ).and_return(:merge_result)

    result = use_case.call(project_context: project_context)

    expect(result.phase).to eq(:merge)
    expect(result.execution_result).to eq(:merge_result)
  end

  it "returns nil execution when no runnable task exists" do
    allow(schedule_next_run).to receive(:call).and_return(
      A3::Application::ScheduleNextRun::Result.new(task: nil, phase: nil, started_run: nil)
    )

    result = use_case.call(project_context: project_context)

    expect(result.task).to be_nil
    expect(result.phase).to be_nil
    expect(result.execution_result).to be_nil
  end
end
