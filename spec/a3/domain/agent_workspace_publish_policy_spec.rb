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

  it "rejects the removed commit hook policy key" do
    expect do
      described_class.native_git_hooks_from("commit_hook_policy" => "run")
    end.to raise_error(A3::Domain::ConfigurationError, /commit_hook_policy.*commit_preflight\.native_git_hooks/)
  end

  it "rejects malformed commit preflight shapes" do
    expect do
      described_class.native_git_hooks_from("commit_preflight" => "run")
    end.to raise_error(A3::Domain::ConfigurationError, /commit_preflight must be a mapping/)
  end

  it "rejects unsupported commit preflight keys" do
    expect do
      described_class.native_git_hooks_from("commit_preflight" => { "unknown" => "run" })
    end.to raise_error(A3::Domain::ConfigurationError, /commit_preflight\.unknown/)
  end
end
