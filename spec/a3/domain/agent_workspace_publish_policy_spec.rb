# frozen_string_literal: true

RSpec.describe A3::Domain::AgentWorkspacePublishPolicy do
  it "defaults missing commit hook policy to bypass" do
    expect(described_class.default_commit_hook_policy(nil)).to eq("bypass")
  end

  it "normalizes supported commit hook policies and rejects unknown values" do
    expect(described_class.normalize_commit_hook_policy("bypass")).to eq("bypass")
    expect(described_class.normalize_commit_hook_policy("run")).to eq("run")

    expect do
      described_class.normalize_commit_hook_policy("sometimes")
    end.to raise_error(A3::Domain::ConfigurationError, /unsupported agent workspace publish_policy commit_hook_policy/)
  end
end
