# frozen_string_literal: true

require "spec_helper"

RSpec.describe A3::Infra::AgentWorkspaceRepoPolicy do
  let(:workspace) do
    A3::Domain::PreparedWorkspace.new(
      workspace_kind: :ticket_workspace,
      root_path: "/tmp/a3-local-workspace",
      source_descriptor: A3::Domain::SourceDescriptor.implementation(task_ref: "Sample#42", ref: "refs/heads/a2o/work/Sample-42"),
      slot_paths: {
        repo_alpha: "/tmp/a3-local-workspace/repo_alpha",
        repo_beta: "/tmp/a3-local-workspace/repo_beta"
      }
    )
  end

  it "returns the required slot set when the workspace matches" do
    policy = described_class.new(available_slots: %i[repo_alpha repo_beta], required_slots: %i[repo_alpha repo_beta])

    expect(policy.resolve_slots(workspace: workspace)).to eq(%i[repo_alpha repo_beta])
  end

  it "fails closed when the materialized workspace is only a subset" do
    policy = described_class.new(available_slots: %i[repo_alpha repo_beta], required_slots: %i[repo_alpha repo_beta])
    partial_workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: workspace.workspace_kind,
      root_path: workspace.root_path,
      source_descriptor: workspace.source_descriptor,
      slot_paths: {repo_alpha: "/tmp/a3-local-workspace/repo_alpha"}
    )

    expect do
      policy.resolve_slots(workspace: partial_workspace)
    end.to raise_error(A3::Domain::ConfigurationError, /missing=repo_beta/)
  end
end
