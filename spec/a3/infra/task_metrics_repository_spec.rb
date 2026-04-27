# frozen_string_literal: true

require "tmpdir"

RSpec.describe "task metrics repositories" do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  def record(task_ref, timestamp)
    A3::Domain::TaskMetricsRecord.new(
      task_ref: task_ref,
      parent_ref: "Sample#1",
      timestamp: timestamp,
      code_changes: { "lines_added" => 10 },
      tests: { "passed_count" => 5 },
      coverage: { "line_percent" => 80.0 },
      timing: { "total_seconds" => 42 },
      cost: { "ai_requests" => 1 },
      custom: { "team" => "alpha" }
    )
  end

  shared_examples "a task metrics repository" do
    it "implements the task metrics repository port" do
      expect(repository.class.ancestors).to include(A3::Domain::TaskMetricsRepository)
    end

    it "persists and lists task metrics records in insertion order" do
      first = record("Sample#2", "2026-04-24T22:42:12Z")
      second = record("Sample#3", "2026-04-24T23:00:00Z")

      repository.save(first)
      repository.save(second)

      expect(repository.all).to eq([first, second])
    end
  end

  context "in memory" do
    let(:repository) { A3::Infra::InMemoryTaskMetricsRepository.new }

    include_examples "a task metrics repository"
  end

  context "JSON" do
    let(:repository) { A3::Infra::JsonTaskMetricsRepository.new(File.join(@tmpdir, "metrics.json")) }

    include_examples "a task metrics repository"

    it "treats truncated JSON as an empty metrics store" do
      File.write(File.join(@tmpdir, "metrics.json"), '[{"task_ref": "Sample#1"')

      expect(repository.all).to eq([])
    end

    it "quarantines malformed JSON before writing a new record" do
      path = File.join(@tmpdir, "metrics.json")
      File.write(path, '{"not":"an array"}')

      repository.save(record("Sample#2", "2026-04-24T22:42:12Z"))

      expect(repository.all.map(&:task_ref)).to eq(["Sample#2"])
      expect(Dir[File.join(@tmpdir, "metrics.json.corrupt.*")]).not_to be_empty
    end
  end

  context "SQLite" do
    let(:repository) { A3::Infra::SqliteTaskMetricsRepository.new(File.join(@tmpdir, "a3.sqlite3")) }

    include_examples "a task metrics repository"
  end
end
