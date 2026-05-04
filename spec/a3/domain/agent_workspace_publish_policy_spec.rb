# frozen_string_literal: true

RSpec.describe A3::Domain::AgentWorkspacePublishPolicy do
  it "defaults missing commit preflight native git hooks to bypass" do
    expect(described_class.native_git_hooks_from({})).to eq("bypass")
  end

  it "normalizes supported commit preflight native git hook policies and rejects unknown values" do
    expect(described_class.normalize_native_git_hooks("bypass")).to eq("bypass")
    expect(described_class.normalize_native_git_hooks("run")).to eq("run")

    expect do
      described_class.normalize_native_git_hooks("sometimes")
    end.to raise_error(A3::Domain::ConfigurationError, /unsupported agent workspace publish_policy commit_preflight\.native_git_hooks/)
  end

  it "keeps explicit nil distinct from a missing native git hooks setting" do
    expect(described_class.native_git_hooks_from("commit_preflight" => { "native_git_hooks" => nil })).to eq("")
  end
end
