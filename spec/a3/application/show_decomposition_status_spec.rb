# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Application::ShowDecompositionStatus do
  it "shows blocked decomposition status from proposal review evidence" do
    Dir.mktmpdir do |dir|
      evidence_dir = File.join(dir, "decomposition-evidence", "A3-v2-5300")
      FileUtils.mkdir_p(evidence_dir)
      File.write(File.join(evidence_dir, "proposal.json"), JSON.generate("proposal_fingerprint" => "abc123"))
      File.write(File.join(evidence_dir, "proposal-review.json"), JSON.generate("disposition" => "blocked", "summary" => "blocked by critical finding"))

      status = described_class.new(storage_dir: dir).call(task_ref: "A3-v2#5300")

      expect(status.state).to eq("blocked")
      expect(status.proposal_fingerprint).to eq("abc123")
      expect(status.disposition).to eq("blocked")
      expect(status.blocked_reason).to eq("blocked by critical finding")
      expect(status.evidence_paths.keys).to include("proposal", "proposal_review")
    end
  end

  it "shows active status when proposal review is eligible but child creation has not run" do
    Dir.mktmpdir do |dir|
      evidence_dir = File.join(dir, "decomposition-evidence", "A3-v2-5300")
      FileUtils.mkdir_p(evidence_dir)
      File.write(File.join(evidence_dir, "proposal.json"), JSON.generate("proposal_fingerprint" => "abc123"))
      File.write(File.join(evidence_dir, "proposal-review.json"), JSON.generate("disposition" => "eligible", "summary" => "ready to create children"))

      status = described_class.new(storage_dir: dir).call(task_ref: "A3-v2#5300")

      expect(status.state).to eq("active")
      expect(status.blocked_reason).to eq("ready to create children")
    end
  end

  it "shows blocked status from failed child creation evidence" do
    Dir.mktmpdir do |dir|
      evidence_dir = File.join(dir, "decomposition-evidence", "A3-v2-5300")
      FileUtils.mkdir_p(evidence_dir)
      File.write(File.join(evidence_dir, "proposal.json"), JSON.generate("proposal_fingerprint" => "abc123"))
      File.write(File.join(evidence_dir, "proposal-review.json"), JSON.generate("disposition" => "eligible", "summary" => "ready"))
      File.write(File.join(evidence_dir, "child-creation.json"), JSON.generate("success" => false, "summary" => "failed to create dependency"))

      status = described_class.new(storage_dir: dir).call(task_ref: "A3-v2#5300")

      expect(status.state).to eq("blocked")
      expect(status.blocked_reason).to eq("failed to create dependency")
      expect(status.evidence_paths.keys).to include("child_creation")
    end
  end

  it "keeps eligible proposal active when no-gate child creation records gate_closed evidence" do
    Dir.mktmpdir do |dir|
      evidence_dir = File.join(dir, "decomposition-evidence", "A3-v2-5300")
      FileUtils.mkdir_p(evidence_dir)
      File.write(File.join(evidence_dir, "proposal.json"), JSON.generate("proposal_fingerprint" => "abc123"))
      File.write(File.join(evidence_dir, "proposal-review.json"), JSON.generate("disposition" => "eligible", "summary" => "ready"))
      File.write(File.join(evidence_dir, "child-creation.json"), JSON.generate("success" => nil, "status" => "gate_closed", "summary" => "decomposition child creation gate is closed"))

      status = described_class.new(storage_dir: dir).call(task_ref: "A3-v2#5300")

      expect(status.state).to eq("active")
      expect(status.blocked_reason).to eq("ready")
      expect(status.evidence_paths.keys).to include("child_creation")
    end
  end

  it "shows done status from successful child creation evidence" do
    Dir.mktmpdir do |dir|
      evidence_dir = File.join(dir, "decomposition-evidence", "A3-v2-5300")
      FileUtils.mkdir_p(evidence_dir)
      File.write(File.join(evidence_dir, "proposal.json"), JSON.generate("proposal_fingerprint" => "abc123"))
      File.write(File.join(evidence_dir, "proposal-review.json"), JSON.generate("disposition" => "eligible", "summary" => "ready"))
      File.write(File.join(evidence_dir, "child-creation.json"), JSON.generate("success" => true, "summary" => "created 2 child tickets"))

      status = described_class.new(storage_dir: dir).call(task_ref: "A3-v2#5300")

      expect(status.state).to eq("done")
      expect(status.evidence_paths.keys).to include("child_creation")
    end
  end
end
