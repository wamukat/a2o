# frozen_string_literal: true

require "pathname"

RSpec.describe A3::Domain::PreparedWorkspace do
  it "rejects a source descriptor that points at a different workspace kind" do
    source_descriptor = A3::Domain::SourceDescriptor.new(
      workspace_kind: :ticket_workspace,
      source_type: :branch_head,
      ref: "refs/heads/a3/work/3025",
      task_ref: "A3-v2#3025"
    )

    expect do
      described_class.new(
        workspace_kind: :runtime_workspace,
        root_path: Pathname("/tmp/a3-v2/runtime"),
        source_descriptor: source_descriptor,
        slot_paths: {
          repo_alpha: Pathname("/tmp/a3-v2/runtime/repo-alpha")
        }
      )
    end.to raise_error(
      A3::Domain::ConfigurationError,
      /prepared workspace kind runtime_workspace does not match source descriptor workspace kind ticket_workspace/
    )
  end
end
