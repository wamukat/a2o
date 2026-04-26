# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Application::RunDecompositionProposalReview do
  FakeReviewStatus = Struct.new(:success?, :exitstatus)

  let(:task) do
    A3::Domain::Task.new(ref: "A3-v2#5300", kind: :single, edit_scope: [:repo_alpha], labels: ["trigger:investigate"], external_task_id: 5300)
  end

  def project_surface(commands)
    A3::Domain::ProjectSurface.new(
      implementation_skill: "skills/implementation.md",
      review_skill: "skills/review.md",
      verification_commands: [],
      remediation_commands: [],
      workspace_hook: nil,
      decomposition_review_commands: commands
    )
  end

  it "marks a clean proposal review eligible and persists evidence" do
    Dir.mktmpdir do |dir|
      proposal_path = File.join(dir, "proposal.json")
      File.write(proposal_path, JSON.generate(
        "success" => true,
        "proposal_fingerprint" => "abc123",
        "proposal" => { "proposal_fingerprint" => "abc123", "children" => [{ "title" => "child" }] }
      ))
      process_runner = lambda do |_command, env:, **|
        File.write(env.fetch("A2O_DECOMPOSITION_REVIEW_RESULT_PATH"), JSON.generate("summary" => "clean", "findings" => []))
        ["", "", FakeReviewStatus.new(true, 0)]
      end

      result = described_class.new(storage_dir: dir, process_runner: process_runner).call(
        task: task,
        project_surface: project_surface([["reviewer"]]),
        proposal_evidence_path: proposal_path
      )

      expect(result.success).to be(true)
      expect(result.disposition).to eq("eligible")
      expect(result.summary).to eq("proposal review clean; eligible for next gate")
      evidence = JSON.parse(File.read(result.evidence_path))
      expect(evidence).to include("phase" => "proposal_review", "disposition" => "eligible")
      expect(evidence.fetch("critical_findings")).to eq([])
    end
  end

  it "blocks when a reviewer reports a critical finding" do
    Dir.mktmpdir do |dir|
      proposal_path = File.join(dir, "proposal.json")
      File.write(proposal_path, JSON.generate(
        "success" => true,
        "proposal_fingerprint" => "abc123",
        "proposal" => { "proposal_fingerprint" => "abc123", "children" => [{ "title" => "child" }] }
      ))
      process_runner = lambda do |_command, env:, **|
        File.write(
          env.fetch("A2O_DECOMPOSITION_REVIEW_RESULT_PATH"),
          JSON.generate("summary" => "blocked", "findings" => [{ "severity" => "critical", "summary" => "missing dependency" }])
        )
        ["", "", FakeReviewStatus.new(true, 0)]
      end

      result = described_class.new(storage_dir: dir, process_runner: process_runner).call(
        task: task,
        project_surface: project_surface([["reviewer"]]),
        proposal_evidence_path: proposal_path
      )

      expect(result.success).to be(false)
      expect(result.disposition).to eq("blocked")
      expect(result.critical_findings.map { |finding| finding.fetch("summary") }).to eq(["missing dependency"])
      evidence = JSON.parse(File.read(result.evidence_path))
      expect(evidence.fetch("disposition")).to eq("blocked")
    end
  end

  it "publishes review disposition to the source ticket when possible" do
    Dir.mktmpdir do |dir|
      proposal_path = File.join(dir, "proposal.json")
      File.write(proposal_path, JSON.generate(
        "success" => true,
        "proposal_fingerprint" => "abc123",
        "proposal" => { "proposal_fingerprint" => "abc123", "children" => [{ "title" => "child" }] }
      ))
      publisher = instance_double(A3::Infra::NullExternalTaskActivityPublisher)
      expect(publisher).to receive(:publish).with(
        task_ref: "A3-v2#5300",
        external_task_id: 5300,
        body: a_string_matching(/Disposition: eligible/)
      )
      process_runner = lambda do |_command, env:, **|
        File.write(env.fetch("A2O_DECOMPOSITION_REVIEW_RESULT_PATH"), JSON.generate("summary" => "clean", "findings" => []))
        ["", "", FakeReviewStatus.new(true, 0)]
      end

      described_class.new(
        storage_dir: dir,
        process_runner: process_runner,
        publish_external_task_activity: publisher
      ).call(
        task: task,
        project_surface: project_surface([["reviewer"]]),
        proposal_evidence_path: proposal_path
      )
    end
  end

  it "blocks when proposal evidence is missing a successful proposal draft" do
    Dir.mktmpdir do |dir|
      proposal_path = File.join(dir, "proposal.json")
      File.write(proposal_path, JSON.generate("success" => false))
      process_runner = lambda do |_command, env:, **|
        File.write(env.fetch("A2O_DECOMPOSITION_REVIEW_RESULT_PATH"), JSON.generate("summary" => "clean", "findings" => []))
        ["", "", FakeReviewStatus.new(true, 0)]
      end

      result = described_class.new(storage_dir: dir, process_runner: process_runner).call(
        task: task,
        project_surface: project_surface([["reviewer"]]),
        proposal_evidence_path: proposal_path
      )

      expect(result.success).to be(false)
      expect(result.disposition).to eq("blocked")
      expect(result.critical_findings.map { |finding| finding.fetch("summary") }).to include("proposal evidence did not succeed")
    end
  end

  it "blocks when reviewer output violates the review result schema" do
    Dir.mktmpdir do |dir|
      proposal_path = File.join(dir, "proposal.json")
      File.write(proposal_path, JSON.generate(
        "success" => true,
        "proposal_fingerprint" => "abc123",
        "proposal" => { "proposal_fingerprint" => "abc123", "children" => [{ "title" => "child" }] }
      ))
      process_runner = lambda do |_command, env:, **|
        File.write(env.fetch("A2O_DECOMPOSITION_REVIEW_RESULT_PATH"), JSON.generate("summary" => "clean", "findings" => "none"))
        ["", "", FakeReviewStatus.new(true, 0)]
      end

      result = described_class.new(storage_dir: dir, process_runner: process_runner).call(
        task: task,
        project_surface: project_surface([["reviewer"]]),
        proposal_evidence_path: proposal_path
      )

      expect(result.success).to be(false)
      expect(result.disposition).to eq("blocked")
      expect(result.critical_findings.map { |finding| finding.fetch("summary") }).to include("review result findings must be an array")
    end
  end
end
