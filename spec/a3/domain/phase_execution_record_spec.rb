# frozen_string_literal: true

RSpec.describe A3::Domain::PhaseExecutionRecord do
  it "serializes and restores the execution observation" do
    record = described_class.new(
      summary: "commands/verify-all ok",
      failing_command: "commands/verify-all",
      observed_state: "exit 0",
      diagnostics: { "stdout" => "ok" },
      runtime_snapshot: A3::Domain::PhaseRuntimeSnapshot.new(
        task_kind: :child,
        repo_scope: :ui_app,
        phase: :review,
        implementation_skill: "sample-implementation",
        review_skill: "sample-review",
        verification_commands: ["commands/check-style", "commands/verify-all"],
        remediation_commands: ["commands/apply-remediation"],
        workspace_hook: "sample-bootstrap",
        merge_target: :merge_to_parent,
        merge_policy: :ff_only
      )
    )

    expect(record.persisted_form).to eq(
      "summary" => "commands/verify-all ok",
      "failing_command" => "commands/verify-all",
      "observed_state" => "exit 0",
      "diagnostics" => { "stdout" => "ok" },
      "review_disposition" => nil,
      "follow_up_child_fingerprints" => [],
      "runtime_snapshot" => {
        "task_kind" => "child",
        "repo_scope" => "ui_app",
        "phase" => "review",
        "implementation_skill" => "sample-implementation",
        "review_skill" => "sample-review",
        "verification_commands" => ["commands/check-style", "commands/verify-all"],
        "remediation_commands" => ["commands/apply-remediation"],
        "workspace_hook" => "sample-bootstrap",
        "merge_target" => "merge_to_parent",
        "merge_policy" => "ff_only"
      }
    )
    expect(described_class.from_persisted_form(record.persisted_form)).to eq(record)
  end

  it "deep-freezes nested diagnostics payloads" do
    nested = { "worker_response_bundle" => { "diagnostics" => { "stderr" => ["boom"] } } }
    record = described_class.new(summary: "blocked", diagnostics: nested)

    expect do
      record.diagnostics.fetch("worker_response_bundle").fetch("diagnostics")["stderr"] << "again"
    end.to raise_error(FrozenError)
  end
end
