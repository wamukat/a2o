# frozen_string_literal: true

require "a3/domain/scheduler_cycle"

RSpec.describe A3::Domain::SchedulerCycle do
  it "serializes and restores the execute-until-idle summary" do
    execution = Struct.new(:task, :phase).new(
      Struct.new(:ref).new("A3-v2#3030"),
      :implementation
    )
    result = Struct.new(:executed_count, :executions, :idle_reached, :stop_reason, :quarantined_count).new(
      4,
      [execution],
      true,
      :idle,
      2
    )
    cycle = described_class.from_execute_until_idle_result(result, cycle_number: 3)

    expect(cycle.persisted_form).to eq(
      "cycle_number" => 3,
      "executed_count" => 4,
      "executed_steps" => [
        {
          "task_ref" => "A3-v2#3030",
          "phase" => "implementation"
        }
      ],
      "idle_reached" => true,
      "stop_reason" => "idle",
      "quarantined_count" => 2
    )
    expect(described_class.from_persisted_form(cycle.persisted_form)).to eq(cycle)
    expect(cycle).to be_frozen
  end

  it "returns a numbered copy immutably" do
    cycle = described_class.new(
      executed_count: 1,
      executed_steps: [A3::Domain::SchedulerCycleStep.new(task_ref: "A3-v2#3030", phase: :review)],
      idle_reached: false,
      stop_reason: :max_steps,
      quarantined_count: 0
    )

    numbered = cycle.with_cycle_number(7)

    expect(cycle.cycle_number).to be_nil
    expect(numbered.cycle_number).to eq(7)
    expect(numbered.executed_count).to eq(1)
    expect(numbered.executed_steps).to eq(
      [A3::Domain::SchedulerCycleStep.new(task_ref: "A3-v2#3030", phase: :review)]
    )
  end
end
