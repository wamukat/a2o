# frozen_string_literal: true

RSpec.describe A3::Application::ReportTaskMetrics do
  let(:repository) { A3::Infra::InMemoryTaskMetricsRepository.new }
  subject(:reporter) { described_class.new(task_metrics_repository: repository) }

  before do
    repository.save(
      A3::Domain::TaskMetricsRecord.new(
        task_ref: "A2O#101",
        parent_ref: "A2O#100",
        timestamp: "2026-04-27T01:00:00Z",
        code_changes: { "lines_added" => 10, "lines_deleted" => 2, "files_changed" => 1 },
        tests: { "passed_count" => 3, "failed_count" => 0 },
        coverage: { "line_percent" => 80.0 }
      )
    )
    repository.save(
      A3::Domain::TaskMetricsRecord.new(
        task_ref: "A2O#102",
        parent_ref: "A2O#100",
        timestamp: "2026-04-27T02:00:00Z",
        code_changes: { "lines_added" => 5, "lines_deleted" => 1, "files_changed" => 2 },
        tests: { "passed_count" => 4, "failed_count" => 1, "skipped_count" => 2 },
        coverage: { "line_percent" => 82.5 }
      )
    )
  end

  it "lists stored metrics records in repository order" do
    expect(reporter.list.map(&:task_ref)).to eq(["A2O#101", "A2O#102"])
  end

  it "summarizes metrics by task by default" do
    entries = reporter.summary

    expect(entries.map(&:group_key)).to eq(["A2O#101", "A2O#102"])
    expect(entries.first.persisted_form).to include(
      "record_count" => 1,
      "task_count" => 1,
      "parent_count" => 1,
      "lines_added" => 10,
      "tests_passed" => 3,
      "latest_line_coverage" => 80.0
    )
  end

  it "summarizes metrics by parent" do
    entries = reporter.summary(group_by: :parent)

    expect(entries.map(&:persisted_form)).to contain_exactly(
      hash_including(
        "group_key" => "A2O#100",
        "record_count" => 2,
        "task_count" => 2,
        "parent_count" => 1,
        "lines_added" => 15,
        "lines_deleted" => 3,
        "files_changed" => 3,
        "tests_passed" => 7,
        "tests_failed" => 1,
        "tests_skipped" => 2,
        "latest_timestamp" => "2026-04-27T02:00:00Z",
        "latest_line_coverage" => 82.5
      )
    )
  end
end
