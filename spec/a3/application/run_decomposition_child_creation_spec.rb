# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Application::RunDecompositionChildCreation do
  WriterResult = Struct.new(:success?, :child_refs, :child_keys, :summary, :diagnostics, keyword_init: true)

  let(:task) { A3::Domain::Task.new(ref: "A3-v2#5300", kind: :single, edit_scope: [:repo_alpha], external_task_id: 5300) }

  def write_evidence(dir, proposal_fingerprint: "fp-1", review_disposition: "eligible")
    evidence_dir = File.join(dir, "decomposition-evidence", "A3-v2-5300")
    FileUtils.mkdir_p(evidence_dir)
    File.write(
      File.join(evidence_dir, "proposal.json"),
      JSON.generate(
        "success" => true,
        "proposal_fingerprint" => proposal_fingerprint,
        "proposal" => {
          "proposal_fingerprint" => proposal_fingerprint,
          "children" => [
            {
              "child_key" => "child-key-1",
              "title" => "Add routing",
              "body" => "Route work.",
              "acceptance_criteria" => ["tested"],
              "labels" => ["repo:alpha"],
              "rationale" => "small boundary"
            }
          ]
        }
      )
    )
    File.write(
      File.join(evidence_dir, "proposal-review.json"),
      JSON.generate(
        "disposition" => review_disposition,
        "request" => {
          "proposal_evidence" => {
            "proposal_fingerprint" => proposal_fingerprint
          }
        }
      )
    )
  end

  it "requires the explicit gate before creating children" do
    Dir.mktmpdir do |dir|
      write_evidence(dir)
      writer = instance_double("ProposalChildWriter")

      result = described_class.new(storage_dir: dir, child_writer: writer).call(task: task, gate: false)

      expect(result.success).to be(false)
      expect(result.summary).to eq("decomposition child creation gate is closed")
    end
  end

  it "creates children only after an eligible proposal review" do
    Dir.mktmpdir do |dir|
      write_evidence(dir)
      writer = instance_double("ProposalChildWriter")
      expect(writer).to receive(:call).with(
        parent_task_ref: "A3-v2#5300",
        parent_external_task_id: 5300,
        proposal_evidence: hash_including("proposal_fingerprint" => "fp-1")
      ).and_return(WriterResult.new(success?: true, child_refs: ["A3-v2#5301"], child_keys: ["child-key-1"]))

      result = described_class.new(storage_dir: dir, child_writer: writer).call(task: task, gate: true)

      expect(result.success).to be(true)
      expect(result.child_refs).to eq(["A3-v2#5301"])
      evidence = JSON.parse(File.read(result.evidence_path))
      expect(evidence.fetch("proposal_fingerprint")).to eq("fp-1")
      expect(evidence.fetch("child_keys")).to eq(["child-key-1"])
    end
  end

  it "blocks when proposal review is not eligible" do
    Dir.mktmpdir do |dir|
      write_evidence(dir, review_disposition: "blocked")
      writer = instance_double("ProposalChildWriter")

      result = described_class.new(storage_dir: dir, child_writer: writer).call(task: task, gate: true)

      expect(result.success).to be(false)
      expect(result.summary).to include("proposal review is not eligible")
    end
  end

  it "blocks when an eligible review belongs to a different proposal fingerprint" do
    Dir.mktmpdir do |dir|
      write_evidence(dir, proposal_fingerprint: "fp-new")
      review_path = File.join(dir, "decomposition-evidence", "A3-v2-5300", "proposal-review.json")
      File.write(
        review_path,
        JSON.generate("disposition" => "eligible", "request" => { "proposal_evidence" => { "proposal_fingerprint" => "fp-old" } })
      )
      writer = instance_double("ProposalChildWriter")

      result = described_class.new(storage_dir: dir, child_writer: writer).call(task: task, gate: true)

      expect(result.success).to be(false)
      expect(result.summary).to include("proposal review fingerprint does not match proposal")
    end
  end
end
