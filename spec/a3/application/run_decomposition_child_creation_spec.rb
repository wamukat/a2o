# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Application::RunDecompositionChildCreation do
  WriterResult = Struct.new(:success?, :child_refs, :child_keys, :summary, :diagnostics, keyword_init: true)

  let(:task) { A3::Domain::Task.new(ref: "A3-v2#5300", kind: :single, edit_scope: [:repo_alpha], external_task_id: 5300) }

  def write_evidence(dir, proposal_fingerprint: "fp-1", review_disposition: "eligible", proposal: nil)
    evidence_dir = File.join(dir, "decomposition-evidence", "A3-v2-5300")
    FileUtils.mkdir_p(evidence_dir)
    proposal ||= {
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
    File.write(
      File.join(evidence_dir, "proposal.json"),
      JSON.generate(
        "success" => true,
        "proposal_fingerprint" => proposal_fingerprint,
        "proposal" => proposal
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

      expect(result.success).to be_nil
      expect(result.status).to eq("gate_closed")
      expect(result.summary).to eq("decomposition child creation gate is closed")
      evidence = JSON.parse(File.read(result.evidence_path))
      expect(evidence.fetch("status")).to eq("gate_closed")
      expect(evidence["success"]).to be_nil
    end
  end

  it "creates children only after an eligible proposal review" do
    Dir.mktmpdir do |dir|
      write_evidence(dir)
      writer = instance_double("ProposalChildWriter")
      expect(writer).to receive(:call).with(
        parent_task_ref: "A3-v2#5300",
        parent_external_task_id: 5300,
        proposal_evidence: hash_including("proposal_fingerprint" => "fp-1"),
        source_remote: nil
      ).and_return(WriterResult.new(success?: true, child_refs: ["A3-v2#5301"], child_keys: ["child-key-1"]))

      result = described_class.new(storage_dir: dir, child_writer: writer).call(task: task, gate: true)

      expect(result.success).to be(true)
      expect(result.status).to eq("created")
      expect(result.child_refs).to eq(["A3-v2#5301"])
      evidence = JSON.parse(File.read(result.evidence_path))
      expect(evidence.fetch("status")).to eq("created")
      expect(evidence.fetch("proposal_fingerprint")).to eq("fp-1")
      expect(evidence.fetch("review_disposition")).to eq("eligible")
      expect(evidence.fetch("child_keys")).to eq(["child-key-1"])
      expect(evidence.fetch("child_refs_by_key")).to eq("child-key-1" => "A3-v2#5301")
      expect(evidence).not_to have_key("source_remote")
      expect(evidence.fetch("source_ticket_summary")).to include("Decomposition draft child creation: completed")
      expect(evidence.fetch("source_ticket_summary")).to include("Accept: add trigger:auto-implement")
      expect(evidence.fetch("source_ticket_summary")).to include("Parent automation: add trigger:auto-parent")
    end
  end

  it "passes imported source remote metadata to the writer and child creation evidence" do
    Dir.mktmpdir do |dir|
      write_evidence(dir)
      source_remote = {
        "provider" => "github",
        "display_ref" => "wamukat/a2o#41",
        "url" => "https://github.com/wamukat/a2o/issues/41"
      }
      writer = instance_double("ProposalChildWriter")
      expect(writer).to receive(:call).with(
        parent_task_ref: "A3-v2#5300",
        parent_external_task_id: 5300,
        proposal_evidence: hash_including("proposal_fingerprint" => "fp-1"),
        source_remote: source_remote
      ).and_return(WriterResult.new(success?: true, child_refs: ["A3-v2#5301"], child_keys: ["child-key-1"]))

      result = described_class.new(storage_dir: dir, child_writer: writer).call(task: task, gate: true, source_remote: source_remote)

      evidence = JSON.parse(File.read(result.evidence_path))
      expect(evidence.fetch("source_remote")).to eq(source_remote)
      expect(evidence.fetch("source_ticket_summary")).not_to include("Source remote:")
    end
  end

  it "blocks child creation when proposal refactoring assessment is invalid" do
    Dir.mktmpdir do |dir|
      write_evidence(
        dir,
        proposal: {
          "proposal_fingerprint" => "fp-1",
          "refactoring_assessment" => {
            "disposition" => "later",
            "recommended_action" => "unknown"
          },
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
      writer = instance_double("ProposalChildWriter")
      expect(writer).not_to receive(:call)

      result = described_class.new(storage_dir: dir, child_writer: writer).call(task: task, gate: true)

      expect(result.success).to be(false)
      expect(result.status).to eq("blocked")
      expect(result.summary).to include("refactoring_assessment.disposition must be one of")
    end
  end

  it "publishes a concise source-ticket audit comment after creating draft children" do
    Dir.mktmpdir do |dir|
      write_evidence(dir)
      writer = instance_double("ProposalChildWriter")
      allow(writer).to receive(:call).and_return(
        WriterResult.new(success?: true, child_refs: ["A3-v2#5301"], child_keys: ["child-key-1"], summary: "created 1 draft child")
      )
      publisher = instance_double("ExternalTaskActivityPublisher")
      expect(publisher).to receive(:publish).with(
        task_ref: "A3-v2#5300",
        external_task_id: 5300,
        body: a_string_including(
          "Decomposition draft child creation: completed",
          "Draft children: A3-v2#5301",
          "trigger:auto-implement"
        )
      )

      result = described_class.new(storage_dir: dir, child_writer: writer, publish_external_task_activity: publisher).call(task: task, gate: true)

      expect(result.source_ticket_summary_published).to be(true)
      expect(result.source_ticket_summary).to include("Draft children: A3-v2#5301")
    end
  end

  it "completes without creating children for no_action outcomes" do
    Dir.mktmpdir do |dir|
      write_evidence(
        dir,
        proposal: {
          "proposal_fingerprint" => "fp-1",
          "outcome" => "no_action",
          "children" => [],
          "reason" => "The requested behavior is already implemented."
        }
      )
      writer = instance_double("ProposalChildWriter")
      expect(writer).not_to receive(:call)

      result = described_class.new(storage_dir: dir, child_writer: writer).call(task: task, gate: true)

      expect(result.success).to be(true)
      expect(result.status).to eq("no_action")
      expect(result.child_refs).to eq([])
      evidence = JSON.parse(File.read(result.evidence_path))
      expect(evidence.fetch("proposal_outcome")).to eq("no_action")
      expect(evidence.fetch("source_ticket_summary")).to include("Outcome: no_action")
      expect(evidence.fetch("source_ticket_summary")).to include("Generated parent: none")
      expect(evidence.fetch("source_ticket_summary")).not_to include("trigger:auto-implement")
      expect(evidence.fetch("source_ticket_summary")).not_to include("trigger:auto-parent")
    end
  end

  it "routes needs_clarification outcomes without creating children" do
    Dir.mktmpdir do |dir|
      write_evidence(
        dir,
        proposal: {
          "proposal_fingerprint" => "fp-1",
          "outcome" => "needs_clarification",
          "children" => [],
          "reason" => "The target audience is unclear.",
          "questions" => ["Which user role should receive this?"]
        }
      )
      writer = instance_double("ProposalChildWriter")
      expect(writer).not_to receive(:call)

      result = described_class.new(storage_dir: dir, child_writer: writer).call(task: task, gate: true)

      expect(result.success).to be(true)
      expect(result.status).to eq("needs_clarification")
      expect(result.source_ticket_summary).to include("Outcome: needs_clarification")
      expect(result.source_ticket_summary).to include("Which user role should receive this?")
      expect(result.source_ticket_summary).not_to include("trigger:auto-implement")
      expect(result.source_ticket_summary).not_to include("trigger:auto-parent")
    end
  end

  it "blocks when proposal review is not eligible" do
    Dir.mktmpdir do |dir|
      write_evidence(dir, review_disposition: "blocked")
      writer = instance_double("ProposalChildWriter")

      result = described_class.new(storage_dir: dir, child_writer: writer).call(task: task, gate: true)

      expect(result.success).to be(false)
      expect(result.status).to eq("blocked")
      expect(result.summary).to include("proposal review is not eligible")
      evidence = JSON.parse(File.read(result.evidence_path))
      expect(evidence.fetch("source_ticket_summary")).to include("Decomposition draft child creation: blocked")
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
