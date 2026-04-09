# frozen_string_literal: true

RSpec.describe A3::Application::ShowSchedulerState do
  subject(:use_case) { described_class.new(scheduler_state_repository: scheduler_state_repository) }

  let(:scheduler_state_repository) { A3::Infra::InMemorySchedulerStateRepository.new }

  before do
    scheduler_state_repository.save(
      A3::Domain::SchedulerState.new(
        paused: true,
        last_stop_reason: :idle,
        last_executed_count: 3
      )
    )
  end

  it "returns operator-facing scheduler state read model" do
    result = use_case.call

    expect(result).to have_attributes(
      paused: true,
      last_stop_reason: :idle,
      last_executed_count: 3,
      status_label: :paused,
      last_cycle_summary: "stop_reason=idle executed_count=3"
    )
    expect(result.active?).to eq(false)
  end
end
