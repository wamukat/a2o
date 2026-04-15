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
      verification_source_ref: "refs/heads/a3/recovered/A3-v2-3025"
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
      "external_task_id" => 3025,
      "verification_source_ref" => "refs/heads/a3/recovered/A3-v2-3025"
    )
    expect(restored).to eq(task)
  end
end
