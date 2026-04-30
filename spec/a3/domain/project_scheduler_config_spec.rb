# frozen_string_literal: true

RSpec.describe A3::Domain::ProjectSchedulerConfig do
  it "defaults max_parallel_tasks to one" do
    expect(described_class.default.max_parallel_tasks).to eq(1)
  end

  it "loads an explicit single-task scheduler config" do
    config = described_class.from_project_config("max_parallel_tasks" => 1)

    expect(config.max_parallel_tasks).to eq(1)
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

  it "fails fast for parallel task counts until scheduler claims and locks exist" do
    expect { described_class.from_project_config("max_parallel_tasks" => 2) }
      .to raise_error(
        A3::Domain::ConfigurationError,
        "project.yaml runtime.scheduler.max_parallel_tasks > 1 is not supported yet; requires scheduler task claims, batch planning, and shared-ref publish/merge locks"
      )
  end
end
