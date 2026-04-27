# frozen_string_literal: true

require "spec_helper"

RSpec.describe A3::Domain::BranchNamespace do
  describe ".normalize" do
    it "returns nil for blank values" do
      expect(described_class.normalize(nil)).to be_nil
      expect(described_class.normalize("///")).to be_nil
    end

    it "strips a3-prefixed path parts and normalizes slashes" do
      expect(described_class.normalize("///runtime//a3-user-check///")).to eq("runtime/user-check")
      expect(described_class.normalize("a3-runtime/a3-review")).to eq("runtime/review")
    end

    it "replaces unsupported characters with hyphens" do
      expect(described_class.normalize("team space/@prod")).to eq("team-space/-prod")
    end
  end

  describe ".from_env" do
    around do |example|
      original_public = ENV["A2O_BRANCH_NAMESPACE"]
      original_legacy = ENV["A3_BRANCH_NAMESPACE"]
      ENV.delete("A2O_BRANCH_NAMESPACE")
      ENV.delete("A3_BRANCH_NAMESPACE")
      example.run
    ensure
      original_public ? ENV["A2O_BRANCH_NAMESPACE"] = original_public : ENV.delete("A2O_BRANCH_NAMESPACE")
      original_legacy ? ENV["A3_BRANCH_NAMESPACE"] = original_legacy : ENV.delete("A3_BRANCH_NAMESPACE")
    end

    it "uses the public A2O branch namespace" do
      ENV["A2O_BRANCH_NAMESPACE"] = "runtime/a2o-check"

      expect(described_class.from_env).to eq("runtime/a2o-check")
    end

    it "rejects the removed A3 branch namespace fallback" do
      ENV["A3_BRANCH_NAMESPACE"] = "runtime/a3-check"

      expect do
        described_class.from_env
      end.to raise_error(A3::Domain::ConfigurationError, /removed A3 compatibility input: environment variable A3_BRANCH_NAMESPACE; migration_required=true replacement=environment variable A2O_BRANCH_NAMESPACE/)
    end
  end
end
