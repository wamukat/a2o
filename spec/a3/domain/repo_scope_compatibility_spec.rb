# frozen_string_literal: true

require "spec_helper"
require "a3/domain/repo_scope_compatibility"

RSpec.describe A3::Domain::RepoScopeCompatibility do
  describe ".prompt_slots" do
    it "prefers canonical repo_slots" do
      result = described_class.prompt_slots(
        repo_scope: "both",
        repo_slots: %i[repo_beta repo_alpha],
        fallback_slots: %i[repo_alpha repo_beta]
      )

      expect(result).to eq(%w[repo_beta repo_alpha])
    end

    it "expands only the legacy both scope through fallback slots" do
      result = described_class.prompt_slots(
        repo_scope: "both",
        repo_slots: [],
        fallback_slots: %i[repo_alpha repo_beta repo_alpha]
      )

      expect(result).to eq(%w[repo_alpha repo_beta])
    end

    it "keeps single legacy repo_scope as one slot" do
      result = described_class.prompt_slots(
        repo_scope: "repo_alpha",
        repo_slots: [],
        fallback_slots: %i[repo_beta]
      )

      expect(result).to eq(["repo_alpha"])
    end
  end
end
