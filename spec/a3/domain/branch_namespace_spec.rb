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
end
