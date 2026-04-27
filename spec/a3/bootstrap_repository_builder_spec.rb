# frozen_string_literal: true

require "tmpdir"
require "a3/bootstrap/repository_builder"
require "a3/bootstrap/repository_registry"

RSpec.describe A3::Bootstrap::RepositoryBuilder do
  it "builds json scheduler repositories alongside task and run repositories" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json"))
      run_repository = A3::Infra::JsonRunRepository.new(File.join(dir, "runs.json"))

      repositories = described_class.new(
        task_repository: task_repository,
        run_repository: run_repository,
        storage_dir: dir
      ).build

      expect(repositories.fetch(:task_repository)).to be(task_repository)
      expect(repositories.fetch(:run_repository)).to be(run_repository)
      expect(repositories.fetch(:task_metrics_repository)).to be_a(A3::Infra::JsonTaskMetricsRepository)
      expect(repositories.fetch(:scheduler_state_repository)).to be_a(A3::Infra::JsonSchedulerStateRepository)
      expect(repositories.fetch(:scheduler_cycle_repository)).to be_a(A3::Infra::JsonSchedulerCycleRepository)
    end
  end

  it "falls back to in-memory scheduler repositories for in-memory task repositories" do
    repositories = described_class.new(
      task_repository: A3::Infra::InMemoryTaskRepository.new,
      run_repository: A3::Infra::InMemoryRunRepository.new,
      storage_dir: "/unused"
    ).build

    expect(repositories.fetch(:scheduler_state_repository)).to be_a(A3::Infra::InMemorySchedulerStateRepository)
    expect(repositories.fetch(:scheduler_cycle_repository)).to be_a(A3::Infra::InMemorySchedulerCycleRepository)
    expect(repositories.fetch(:task_metrics_repository)).to be_a(A3::Infra::InMemoryTaskMetricsRepository)
  end

  it "wires sqlite scheduler state/cycle repositories to the same shared sqlite store" do
    Dir.mktmpdir do |dir|
      db_path = File.join(dir, "a3.sqlite3")
      repositories = A3::Bootstrap::RepositoryRegistry.build(
        task_repository: A3::Infra::SqliteTaskRepository.new(db_path),
        run_repository: A3::Infra::SqliteRunRepository.new(db_path),
        storage_dir: dir
      )

      scheduler_state_repository = repositories.fetch(:scheduler_state_repository)
      scheduler_cycle_repository = repositories.fetch(:scheduler_cycle_repository)
      shared_store = scheduler_state_repository.instance_variable_get(:@store)

      expect(scheduler_state_repository).to be_a(A3::Infra::SqliteSchedulerStateRepository)
      expect(scheduler_cycle_repository).to be_a(A3::Infra::SqliteSchedulerCycleRepository)
      expect(repositories.fetch(:task_metrics_repository)).to be_a(A3::Infra::SqliteTaskMetricsRepository)
      expect(scheduler_cycle_repository.instance_variable_get(:@store)).to be(shared_store)

      previous_state = A3::Domain::SchedulerState.new(
        paused: false,
        last_stop_reason: :idle,
        last_executed_count: 1
      )
      scheduler_state_repository.save(previous_state)
      persisted_cycle = scheduler_cycle_repository.append(
        A3::Domain::SchedulerCycle.new(
          executed_count: 1,
          idle_reached: true,
          stop_reason: :idle,
          quarantined_count: 0
        )
      )

      expect do
        scheduler_state_repository.record_cycle_result(
          next_state: A3::Domain::SchedulerState.new(
            paused: true,
            last_stop_reason: :max_steps,
            last_executed_count: 9
          ),
          cycle: A3::Domain::SchedulerCycle.new(
            cycle_number: persisted_cycle.cycle_number,
            executed_count: 9,
            idle_reached: false,
            stop_reason: :max_steps,
            quarantined_count: 2
          )
        )
      end.to raise_error(SQLite3::ConstraintException)

      expect(scheduler_state_repository.fetch).to eq(previous_state)
      expect(scheduler_cycle_repository.all).to eq([persisted_cycle])
    end
  end
end
