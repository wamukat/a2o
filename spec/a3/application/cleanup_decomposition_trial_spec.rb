# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe A3::Application::CleanupDecompositionTrial do
  def write_trial(storage_dir)
    evidence_dir = File.join(storage_dir, "decomposition-evidence", "A3-v2-5300")
    workspace_dir = File.join(storage_dir, "decomposition-workspaces", "A3-v2-5300")
    FileUtils.mkdir_p(evidence_dir)
    FileUtils.mkdir_p(workspace_dir)
    File.write(
      File.join(evidence_dir, "proposal.json"),
      JSON.generate(
        "phase" => "proposal",
        "success" => true,
        "proposal_fingerprint" => "fp-1",
        "proposal" => {
          "children" => [
            { "child_key" => "child-key-1" }
          ]
        }
      )
    )
    File.write(
      File.join(evidence_dir, "child-creation.json"),
      JSON.generate(
        "phase" => "child_creation",
        "status" => "gate_closed",
        "success" => nil,
        "proposal_fingerprint" => "fp-1",
        "child_refs" => ["A3-v2#5301"],
        "child_keys" => ["child-key-1"]
      )
    )
    File.write(File.join(workspace_dir, "scratch.txt"), "trial")
  end

  it "reports trial cleanup targets without deleting by default" do
    Dir.mktmpdir do |dir|
      write_trial(dir)

      result = described_class.new(storage_dir: dir).call(task_ref: "A3-v2#5300")

      expect(result.mode).to eq("dry-run")
      expect(result.target_paths.map(&:exists)).to all(be(true))
      expect(result.deleted_paths).to be_empty
      expect(result.proposal_fingerprint).to eq("fp-1")
      expect(result.child_refs).to eq(["A3-v2#5301"])
      expect(result.child_keys).to eq(["child-key-1"])
      expect(result.evidence_records.map(&:status)).to include("gate_closed")
      expect(File.exist?(File.join(dir, "decomposition-evidence", "A3-v2-5300"))).to be(true)
      expect(File.exist?(File.join(dir, "decomposition-workspaces", "A3-v2-5300"))).to be(true)
    end
  end

  it "deletes only the matching task slug when apply is explicit" do
    Dir.mktmpdir do |dir|
      write_trial(dir)
      other_dir = File.join(dir, "decomposition-evidence", "Other-5300")
      FileUtils.mkdir_p(other_dir)
      File.write(File.join(other_dir, "proposal.json"), JSON.generate("proposal_fingerprint" => "fp-other"))

      result = described_class.new(storage_dir: dir).call(task_ref: "A3-v2#5300", apply: true)

      expect(result.mode).to eq("apply")
      expect(result.deleted_paths).to include(
        File.join(dir, "decomposition-evidence", "A3-v2-5300"),
        File.join(dir, "decomposition-workspaces", "A3-v2-5300")
      )
      expect(File.exist?(File.join(dir, "decomposition-evidence", "A3-v2-5300"))).to be(false)
      expect(File.exist?(File.join(dir, "decomposition-workspaces", "A3-v2-5300"))).to be(false)
      expect(File.exist?(other_dir)).to be(true)
    end
  end

  it "refuses to apply cleanup through symlinked storage paths" do
    Dir.mktmpdir do |dir|
      external_dir = File.join(dir, "external")
      FileUtils.mkdir_p(File.join(external_dir, "A3-v2-5300"))
      FileUtils.ln_s(external_dir, File.join(dir, "decomposition-evidence"))

      expect do
        described_class.new(storage_dir: dir).call(task_ref: "A3-v2#5300", apply: true)
      end.to raise_error(ArgumentError, /contains symlink/)
      expect(File.exist?(File.join(external_dir, "A3-v2-5300"))).to be(true)
    end
  end

  it "refuses to dry-run cleanup through symlinked evidence paths before reading evidence" do
    Dir.mktmpdir do |dir|
      external_dir = File.join(dir, "external")
      FileUtils.mkdir_p(File.join(external_dir, "A3-v2-5300"))
      File.write(File.join(external_dir, "A3-v2-5300", "proposal.json"), JSON.generate("proposal_fingerprint" => "external"))
      FileUtils.ln_s(external_dir, File.join(dir, "decomposition-evidence"))

      expect do
        described_class.new(storage_dir: dir).call(task_ref: "A3-v2#5300")
      end.to raise_error(ArgumentError, /contains symlink/)
    end
  end
end
