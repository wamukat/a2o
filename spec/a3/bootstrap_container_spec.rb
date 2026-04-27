# frozen_string_literal: true

require "tmpdir"
require "a3/bootstrap/container"

RSpec.describe A3::Bootstrap::Container do
  it "assembles a backend-selected container via a single public entrypoint" do
    Dir.mktmpdir do |dir|
      container = described_class.build(
        storage_backend: :sqlite,
        storage_dir: dir,
        repo_sources: {},
        run_id_generator: -> { "run-1" }
      )

      expect(container.fetch(:task_repository)).to be_a(A3::Infra::SqliteTaskRepository)
      expect(container.fetch(:run_repository)).to be_a(A3::Infra::SqliteRunRepository)
      expect(container.fetch(:task_metrics_repository)).to be_a(A3::Infra::SqliteTaskMetricsRepository)
      expect(container.fetch(:scheduler_state_repository)).to be_a(A3::Infra::SqliteSchedulerStateRepository)
      expect(container.fetch(:scheduler_cycle_repository)).to be_a(A3::Infra::SqliteSchedulerCycleRepository)
    end
  end

  it "assembles a json-backed scheduler/operator container" do
    Dir.mktmpdir do |dir|
      container = described_class.json(
        storage_dir: dir,
        repo_sources: {},
        run_id_generator: -> { "run-1" }
      )

      expect(container).to include(
        :task_repository,
        :run_repository,
        :task_metrics_repository,
        :scheduler_state_repository,
        :scheduler_cycle_repository,
        :show_task,
        :show_run,
        :report_task_metrics,
        :show_scheduler_history,
        :plan_next_runnable_task,
        :schedule_next_run,
        :execute_next_runnable_task,
        :execute_until_idle
      )
    end
  end

  it "reuses the same scheduler store for state and cycle repositories when built from explicit repositories" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json"))
      run_repository = A3::Infra::JsonRunRepository.new(File.join(dir, "runs.json"))
      container = described_class.new(
        task_repository: task_repository,
        run_repository: run_repository,
        run_id_generator: -> { "run-1" },
        command_runner: A3::Infra::LocalCommandRunner.new,
        merge_runner: A3::Infra::DisabledMergeRunner.new,
        worker_gateway: nil,
        storage_dir: dir,
        repo_sources: {}
      ).build

      state_repository = container.fetch(:scheduler_state_repository)
      cycle_repository = container.fetch(:scheduler_cycle_repository)

      expect(state_repository.instance_variable_get(:@store)).to be(cycle_repository.instance_variable_get(:@store))
    end
  end

  it "raises for unsupported container storage backends" do
    expect do
      described_class.build(
        storage_backend: :unsupported,
        storage_dir: "/tmp",
        repo_sources: {},
        run_id_generator: -> { "run-1" }
      )
    end.to raise_error(ArgumentError, /unsupported storage backend/)
  end
end
