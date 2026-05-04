# frozen_string_literal: true

RSpec.describe A3::Application::WatchSummaryPhaseProjection do
  def phase_record(phase, terminal_outcome = :completed)
    described_class::PhaseRecord.new(phase: phase, terminal_outcome: terminal_outcome)
  end

  it "hides later phase records from older cycles after an earlier phase rerun starts" do
    result = described_class.call(
      latest_phase: "review",
      records: [
        phase_record("implementation"),
        phase_record("review"),
        phase_record("inspection"),
        phase_record("implementation"),
        phase_record("review", nil)
      ]
    )

    expect(result.phase_counts).to eq("implementation" => 2, "review" => 2)
    expect(result.phase_states).to eq("implementation" => :done, "review" => :done)
  end

  it "marks review rework as failed for formatter phase bars" do
    result = described_class.call(
      latest_phase: "review",
      records: [
        phase_record("implementation"),
        phase_record("review", :rework)
      ]
    )

    expect(result.phase_counts).to eq("implementation" => 1, "review" => 1)
    expect(result.phase_states).to eq("implementation" => :done, "review" => :failed)
  end
end
