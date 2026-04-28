# frozen_string_literal: true

RSpec.describe A3::Domain::TaskMetricsRecord do
  let(:timestamp) { "2026-04-24T22:42:12Z" }

  it "builds a persisted metrics record from project-provided sections and A2O-owned sections" do
    record = described_class.from_project_metrics(
      task_ref: "MemberPortal#65",
      parent_ref: "MemberPortal#64",
      timestamp: timestamp,
      payload: {
        "task_ref" => "MemberPortal#65",
        "parent_ref" => "MemberPortal#64",
        "timestamp" => timestamp,
        "code_changes" => {
          "lines_added" => 245,
          "lines_modified" => 38,
          "lines_deleted" => 12,
          "files_changed" => 20
        },
        "tests" => {
          "total_count" => 312,
          "added_count" => 8,
          "passed_count" => 312,
          "failed_count" => 0
        },
        "coverage" => {
          "line_percent" => 78.3,
          "branch_percent" => 65.1
        },
        "custom" => {
          "team" => "portal"
        }
      },
      timing: {
        implementation_seconds: 1661,
        verification_seconds: 1411,
        total_seconds: 3078,
        rework_count: 0
      },
      cost: {
        ai_requests: 1,
        tokens_input: 6_100_000,
        tokens_output: 32_400
      }
    )

    expect(record.persisted_form).to eq(
      "task_ref" => "MemberPortal#65",
      "parent_ref" => "MemberPortal#64",
      "timestamp" => timestamp,
      "code_changes" => {
        "lines_added" => 245,
        "lines_modified" => 38,
        "lines_deleted" => 12,
        "files_changed" => 20
      },
      "tests" => {
        "total_count" => 312,
        "added_count" => 8,
        "passed_count" => 312,
        "failed_count" => 0
      },
      "coverage" => {
        "line_percent" => 78.3,
        "branch_percent" => 65.1
      },
      "timing" => {
        "implementation_seconds" => 1661,
        "verification_seconds" => 1411,
        "total_seconds" => 3078,
        "rework_count" => 0
      },
      "cost" => {
        "ai_requests" => 1,
        "tokens_input" => 6_100_000,
        "tokens_output" => 32_400
      },
      "custom" => {
        "team" => "portal"
      }
    )
  end

  it "rejects non-object project metrics payloads with a clear error" do
    expect do
      described_class.from_project_metrics(
        task_ref: "MemberPortal#65",
        timestamp: timestamp,
        payload: ["not", "an", "object"]
      )
    end.to raise_error(ArgumentError, "task metrics payload must be a JSON object")
  end

  it "rejects non-object metric sections with a clear error" do
    expect do
      described_class.from_project_metrics(
        task_ref: "MemberPortal#65",
        timestamp: timestamp,
        payload: { "tests" => "312 passed" }
      )
    end.to raise_error(ArgumentError, "task metrics tests must be a JSON object")
  end

  it "rejects unsupported project-provided top-level sections" do
    expect do
      described_class.from_project_metrics(
        task_ref: "MemberPortal#65",
        timestamp: timestamp,
        payload: { "unsupported" => {} }
      )
    end.to raise_error(ArgumentError, "task metrics payload contains unsupported section(s): unsupported")
  end

  it "accepts timing and cost sections from the metrics payload when runtime values are not provided" do
    record = described_class.from_project_metrics(
      task_ref: "MemberPortal#65",
      timestamp: timestamp,
      payload: {
        "timing" => { "total_seconds" => 12 },
        "cost" => { "ai_requests" => 1 }
      }
    )

    expect(record.timing).to eq("total_seconds" => 12)
    expect(record.cost).to eq("ai_requests" => 1)
  end

  it "rejects project metadata that does not match the runtime task context" do
    expect do
      described_class.from_project_metrics(
        task_ref: "MemberPortal#65",
        timestamp: timestamp,
        payload: {
          "task_ref" => "MemberPortal#999",
          "code_changes" => {}
        }
      )
    end.to raise_error(ArgumentError, "task metrics task_ref does not match runtime task context")
  end

  it "round-trips through persisted form" do
    record = described_class.new(
      task_ref: "MemberPortal#65",
      timestamp: timestamp,
      code_changes: { "lines_added" => 1 }
    )

    expect(described_class.from_persisted_form(record.persisted_form)).to eq(record)
  end

  it "carries project identity from runtime context or payload" do
    record = described_class.from_project_metrics(
      task_ref: "MemberPortal#65",
      project_key: "portal",
      timestamp: timestamp,
      payload: {
        "project_key" => "portal",
        "code_changes" => { "files_changed" => 2 }
      }
    )

    expect(record.project_key).to eq("portal")
    expect(record.persisted_form.fetch("project_key")).to eq("portal")
    expect(described_class.from_persisted_form(record.persisted_form)).to eq(record)
  end
end
