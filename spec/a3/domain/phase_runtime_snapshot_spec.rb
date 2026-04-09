# frozen_string_literal: true

RSpec.describe A3::Domain::PhaseRuntimeSnapshot do
  it "serializes and restores a runtime snapshot" do
    snapshot = described_class.new(
      task_kind: :child,
      repo_scope: :repo_alpha,
      phase: :review,
      implementation_skill: "sample-implementation",
      review_skill: "sample-review",
      verification_commands: ["commands/check-style", "commands/verify-all"],
      remediation_commands: ["commands/apply-remediation"],
      workspace_hook: "sample-bootstrap",
      merge_target: :merge_to_parent,
      merge_policy: :ff_only
    )

    expect(described_class.from_persisted_form(snapshot.persisted_form)).to eq(snapshot)
  end
end
