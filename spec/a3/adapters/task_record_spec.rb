# frozen_string_literal: true

RSpec.describe A3::Adapters::TaskRecord do
  it "serializes and restores a task without losing immutable state" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha, :repo_beta],
      status: :in_review,
      current_run_ref: "run-1",
      parent_ref: "A3-v2#3022",
      external_task_id: 3025,
      verification_source_ref: "refs/heads/a2o/recovered/A3-v2-3025",
      labels: ["repo:alpha", "review:light"]
    )

    record = described_class.dump(task)
    restored = described_class.load(record)

    expect(record).to eq(
      "ref" => "A3-v2#3025",
      "kind" => "child",
      "edit_scope" => ["repo_alpha"],
      "verification_scope" => ["repo_alpha", "repo_beta"],
      "status" => "in_review",
      "current_run_ref" => "run-1",
      "parent_ref" => "A3-v2#3022",
      "child_refs" => [],
      "blocking_task_refs" => [],
      "priority" => 0,
      "external_task_id" => 3025,
      "verification_source_ref" => "refs/heads/a2o/recovered/A3-v2-3025",
      "automation_enabled" => true,
      "labels" => ["repo:alpha", "review:light"]
    )
    expect(restored).to eq(task)
  end

  it "serializes project identity and keeps legacy records readable in single-project mode" do
    task = A3::Domain::Task.new(
      ref: "A2O#312",
      kind: :single,
      edit_scope: [:a2o],
      project_key: "a2o"
    )

    record = described_class.dump(task)

    expect(record.fetch("project_key")).to eq("a2o")
    expect(described_class.load(record).project_key).to eq("a2o")
    expect(described_class.load(record.except("project_key")).project_key).to be_nil
  end

  it "rejects ambiguous legacy task records in multi-project mode" do
    legacy_record = described_class.dump(
      A3::Domain::Task.new(ref: "A2O#312", kind: :single, edit_scope: [:a2o])
    )

    with_env("A2O_MULTI_PROJECT_MODE" => "1") do
      expect do
        described_class.load(legacy_record)
      end.to raise_error(A3::Domain::ConfigurationError, /legacy record without project_key is ambiguous/)
    end
  end
end
