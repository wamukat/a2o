# frozen_string_literal: true

RSpec.describe A3::Domain::ProjectSchedulerConfig do
  it "defaults max_parallel_tasks to one" do
    expect(described_class.default.max_parallel_tasks).to eq(1)
  end

  it "defaults no-commit rework loop detection to three" do
    expect(described_class.default.max_consecutive_rework_without_commit).to eq(3)
  end

  it "loads an explicit single-task scheduler config" do
    config = described_class.from_project_config("max_parallel_tasks" => 1)

    expect(config.max_parallel_tasks).to eq(1)
    expect(config.max_consecutive_rework_without_commit).to eq(3)
  end

  it "loads the root runtime no-commit rework limit" do
    config = described_class.from_project_config(
      { "max_parallel_tasks" => 2 },
      runtime: { "max_consecutive_rework_without_commit" => 4 }
    )

    expect(config.max_parallel_tasks).to eq(2)
    expect(config.max_consecutive_rework_without_commit).to eq(4)
  end

  it "rejects malformed scheduler config" do
    expect { described_class.from_project_config([]) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.scheduler must be a mapping")
  end

  it "rejects non-integer max_parallel_tasks" do
    expect { described_class.from_project_config("max_parallel_tasks" => "2") }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.scheduler.max_parallel_tasks must be an integer")
  end

  it "rejects max_parallel_tasks lower than one" do
    expect { described_class.from_project_config("max_parallel_tasks" => 0) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.scheduler.max_parallel_tasks must be greater than or equal to 1")
  end

  it "rejects non-integer no-commit rework limits" do
    expect { described_class.from_project_config(nil, runtime: { "max_consecutive_rework_without_commit" => "3" }) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.max_consecutive_rework_without_commit must be an integer")
  end

  it "rejects no-commit rework limits lower than one" do
    expect { described_class.from_project_config(nil, runtime: { "max_consecutive_rework_without_commit" => 0 }) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.max_consecutive_rework_without_commit must be greater than or equal to 1")
  end

  it "loads explicit bounded parallel task counts" do
    config = described_class.from_project_config("max_parallel_tasks" => 2)

    expect(config.max_parallel_tasks).to eq(2)
  end
end
