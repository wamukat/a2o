# frozen_string_literal: true

RSpec.describe A3::Application::ShowSchedulerHistory do
  subject(:use_case) { described_class.new(scheduler_cycle_repository: scheduler_cycle_repository) }

  let(:scheduler_cycle_repository) { A3::Infra::InMemorySchedulerCycleRepository.new }

  before do
    scheduler_cycle_repository.append(
      A3::Domain::SchedulerCycle.new(
        executed_count: 2,
        idle_reached: true,
        stop_reason: :idle,
        quarantined_count: 1
      )
    )
  end

  it "returns persisted scheduler cycles in append order" do
    result = use_case.call

    expect(result.map(&:cycle_number)).to eq([1])
    expect(result.first.executed_count).to eq(2)
    expect(result.first.stop_reason).to eq(:idle)
    expect(result.first.summary).to eq("cycle=1 executed=2 idle=true stop_reason=idle quarantined=1")
  end
end
