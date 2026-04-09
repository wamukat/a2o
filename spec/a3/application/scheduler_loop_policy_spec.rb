# frozen_string_literal: true

RSpec.describe A3::Application::SchedulerLoopPolicy do
  subject(:policy) { described_class.new }

  it "builds the paused result" do
    result = policy.paused_result

    expect(result.executions).to eq([])
    expect(result.executed_count).to eq(0)
    expect(result.idle_reached).to eq(false)
    expect(result.stop_reason).to eq(:paused)
    expect(result.quarantined_count).to eq(0)
  end

  it "derives the idle stop reason when the cycle reached idle" do
    cycle_result = A3::Application::SchedulerCycleExecutor::Result.new(
      executions: [
        A3::Application::ExecuteNextRunnableTask::Result.new(
          task: A3::Domain::Task.new(ref: "A3-v2#3030", kind: :child, edit_scope: [:repo_alpha]),
          phase: :implementation,
          started_run: :started_1,
          execution_result: :result_1
        )
      ],
      executed_count: 1,
      idle_reached: true,
      paused_reached: false
    )

    result = policy.result_for(cycle_result: cycle_result, quarantined_count: 2)

    expect(result.executions).to eq(cycle_result.executions)
    expect(result.executed_count).to eq(1)
    expect(result.idle_reached).to eq(true)
    expect(result.stop_reason).to eq(:idle)
    expect(result.quarantined_count).to eq(2)
  end

  it "derives the max_steps stop reason when the cycle is not idle" do
    cycle_result = A3::Application::SchedulerCycleExecutor::Result.new(
      executions: [],
      executed_count: 1,
      idle_reached: false,
      paused_reached: false
    )

    result = policy.result_for(cycle_result: cycle_result, quarantined_count: 0)

    expect(result.stop_reason).to eq(:max_steps)
  end

  it "derives the paused stop reason when pause is requested mid-cycle" do
    cycle_result = A3::Application::SchedulerCycleExecutor::Result.new(
      executions: [],
      executed_count: 1,
      idle_reached: false,
      paused_reached: true
    )

    result = policy.result_for(cycle_result: cycle_result, quarantined_count: 0)

    expect(result.stop_reason).to eq(:paused)
  end
end
