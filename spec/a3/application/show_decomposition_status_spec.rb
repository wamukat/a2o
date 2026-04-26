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
end
