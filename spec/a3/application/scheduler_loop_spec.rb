# frozen_string_literal: true

RSpec.describe A3::Application::SchedulerLoop do
  let(:execute_next_runnable_task) { instance_double(A3::Application::ExecuteNextRunnableTask) }
  let(:cycle_journal) { instance_double(A3::Application::SchedulerCycleJournal) }
  let(:quarantine_runner) { instance_double(A3::Application::SchedulerQuarantineRunner) }
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

  subject(:loop) do
    described_class.new(
      execute_next_runnable_task: execute_next_runnable_task,
      cycle_journal: cycle_journal,
      quarantine_runner: quarantine_runner
    )
  end

  it "short circuits when the scheduler is paused" do
    allow(cycle_journal).to receive(:paused?).and_return(true)

    result = loop.call(project_context: project_context)

    expect(result.stop_reason).to eq(:paused)
    expect(execute_next_runnable_task).not_to receive(:call)
  end

  it "runs until idle and records the cycle through collaborators" do
    allow(cycle_journal).to receive(:paused?).and_return(false)
    allow(execute_next_runnable_task).to receive(:call).and_return(
      A3::Application::ExecuteNextRunnableTask::Result.new(
        task: A3::Domain::Task.new(ref: "A3-v2#3030", kind: :child, edit_scope: [:repo_alpha]),
        phase: :implementation,
        started_run: :started,
        execution_result: :result
      ),
      A3::Application::ExecuteNextRunnableTask::Result.new(
        task: nil,
        phase: nil,
        started_run: nil,
        execution_result: nil
      )
    )
    allow(quarantine_runner).to receive(:call).and_return(1)
    allow(cycle_journal).to receive(:record).and_return(
      A3::Domain::SchedulerCycle.new(
        cycle_number: 1,
        executed_count: 1,
        idle_reached: true,
        stop_reason: :idle,
        quarantined_count: 1
      )
    )

    result = loop.call(project_context: project_context)

    expect(result.executed_count).to eq(1)
    expect(result.stop_reason).to eq(:idle)
    expect(cycle_journal).to have_received(:record)
    expect(quarantine_runner).to have_received(:call)
  end

  it "stops scheduling additional tasks when pause is requested during the cycle" do
    paused_state = false
    allow(cycle_journal).to receive(:paused?) { paused_state }
    allow(execute_next_runnable_task).to receive(:call) do
      paused_state = true
      A3::Application::ExecuteNextRunnableTask::Result.new(
        task: A3::Domain::Task.new(ref: "A3-v2#3030", kind: :child, edit_scope: [:repo_alpha]),
        phase: :implementation,
        started_run: :started,
        execution_result: :result
      )
    end
    allow(quarantine_runner).to receive(:call).and_return(0)
    allow(cycle_journal).to receive(:record).and_return(
      A3::Domain::SchedulerCycle.new(
        cycle_number: 2,
        executed_count: 1,
        idle_reached: false,
        stop_reason: :paused,
        quarantined_count: 0
      )
    )

    result = loop.call(project_context: project_context)

    expect(result.executed_count).to eq(1)
    expect(result.stop_reason).to eq(:paused)
    expect(execute_next_runnable_task).to have_received(:call).once
  end
end
