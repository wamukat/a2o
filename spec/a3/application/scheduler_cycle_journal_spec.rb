# frozen_string_literal: true

RSpec.describe A3::Application::SchedulerCycleJournal do
  let(:scheduler_store) { A3::Infra::InMemorySchedulerStore.new }
  let(:state_repository) { A3::Infra::InMemorySchedulerStateRepository.new(scheduler_store) }
  let(:cycle_repository) { A3::Infra::InMemorySchedulerCycleRepository.new(scheduler_store) }

  subject(:journal) do
    described_class.new(
      scheduler_state_repository: state_repository,
      scheduler_cycle_repository: cycle_repository
    )
  end

  it "reports the paused scheduler state" do
    state_repository.save(A3::Domain::SchedulerState.new(paused: true))

    expect(journal.paused?).to eq(true)
  end

  it "records a cycle and persists the summary state" do
    state_repository.save(A3::Domain::SchedulerState.new)
    result = A3::Application::ExecuteUntilIdle::Result.new(
      executions: [].freeze,
      executed_count: 1,
      idle_reached: true,
      stop_reason: :idle,
      quarantined_count: 2,
      scheduler_cycle: nil
    )

    cycle = journal.record(result)

    expect(cycle.cycle_number).to eq(1)
    expect(cycle_repository.all).to eq([cycle])
    expect(state_repository.fetch.last_stop_reason).to eq(:idle)
    expect(state_repository.fetch.last_executed_count).to eq(1)
  end

  it "does not append a cycle when persisting state fails" do
    failing_state_repository = Class.new(A3::Infra::InMemorySchedulerStateRepository) do
      def record_cycle_result(next_state:, cycle:)
        raise "boom"
      end
    end.new(scheduler_store)
    rollback_journal = described_class.new(
      scheduler_state_repository: failing_state_repository,
      scheduler_cycle_repository: cycle_repository
    )
    result = A3::Application::ExecuteUntilIdle::Result.new(
      executions: [].freeze,
      executed_count: 1,
      idle_reached: true,
      stop_reason: :idle,
      quarantined_count: 0,
      scheduler_cycle: nil
    )

    expect do
      rollback_journal.record(result)
    end.to raise_error("boom")
    expect(cycle_repository.all).to eq([])
  end

  it "raises when the repositories do not share the same scheduler store" do
    mismatched_cycle_repository = A3::Infra::InMemorySchedulerCycleRepository.new(A3::Infra::InMemorySchedulerStore.new)

    expect do
      described_class.new(
        scheduler_state_repository: state_repository,
        scheduler_cycle_repository: mismatched_cycle_repository
      )
    end.to raise_error(ArgumentError, /share the same scheduler store/)
  end

  it "uses an atomic state+cycle write contract" do
    tracking_state_repository = Class.new(A3::Infra::InMemorySchedulerStateRepository) do
      attr_reader :recorded_next_state, :recorded_cycle

      def record_cycle_result(next_state:, cycle:)
        @recorded_next_state = next_state
        @recorded_cycle = cycle
        super
      end
    end.new(scheduler_store)
    journal = described_class.new(
      scheduler_state_repository: tracking_state_repository,
      scheduler_cycle_repository: cycle_repository
    )
    result = A3::Application::ExecuteUntilIdle::Result.new(
      executions: [].freeze,
      executed_count: 2,
      idle_reached: true,
      stop_reason: :idle,
      quarantined_count: 1,
      scheduler_cycle: nil
    )

    cycle = journal.record(result)

    expect(tracking_state_repository.recorded_next_state).to have_attributes(
      last_stop_reason: :idle,
      last_executed_count: 2
    )
    expect(tracking_state_repository.recorded_cycle).to have_attributes(
      cycle_number: nil,
      executed_count: 2,
      stop_reason: :idle
    )
    expect(cycle_repository.all).to eq([cycle])
  end
end
