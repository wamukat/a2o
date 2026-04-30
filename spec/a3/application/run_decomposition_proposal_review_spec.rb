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

  it "marks an eligible proposal review and persists evidence" do
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
      expect(result.summary).to eq("proposal review eligible for next gate")
      workspace_root = JSON.parse(File.read(result.evidence_path)).fetch("workspace_root")
      expect(File.stat(workspace_root).mode & 0o777).to eq(0o777)
      expect(File.stat(File.join(workspace_root, ".a2o")).mode & 0o777).to eq(0o777)
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

  it "records reviewer refactoring assessments in evidence and source summaries" do
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
        body: a_string_matching(/Refactoring assessment: defer_follow_up action=create_follow_up_child risk=medium scope=repo_alpha reason=Duplicate setup belongs in a follow-up\./)
      )
      process_runner = lambda do |_command, env:, **|
        File.write(
          env.fetch("A2O_DECOMPOSITION_REVIEW_RESULT_PATH"),
          JSON.generate(
            "summary" => "clean",
            "findings" => [],
            "refactoring_assessment" => {
              "disposition" => "defer_follow_up",
              "reason" => "Duplicate setup belongs in a follow-up.",
              "scope" => ["repo_alpha"],
              "recommended_action" => "create_follow_up_child",
              "risk" => "medium",
              "evidence" => ["Two setup helpers overlap."]
            }
          )
        )
        ["", "", FakeReviewStatus.new(true, 0)]
      end

      result = described_class.new(
        storage_dir: dir,
        process_runner: process_runner,
        publish_external_task_activity: publisher
      ).call(
        task: task,
        project_surface: project_surface([["reviewer"]]),
        proposal_evidence_path: proposal_path
      )

      expect(result.success).to be(true)
      evidence = JSON.parse(File.read(result.evidence_path))
      expect(evidence.fetch("review_results").first.fetch("refactoring_assessment")).to include(
        "disposition" => "defer_follow_up",
        "recommended_action" => "create_follow_up_child"
      )
    end
  end

  it "blocks when proposal evidence contains an invalid refactoring assessment" do
    Dir.mktmpdir do |dir|
      proposal_path = File.join(dir, "proposal.json")
      File.write(proposal_path, JSON.generate(
        "success" => true,
        "proposal_fingerprint" => "abc123",
        "proposal" => {
          "proposal_fingerprint" => "abc123",
          "children" => [{ "title" => "child" }],
          "refactoring_assessment" => {
            "disposition" => "later",
            "recommended_action" => "unknown"
          }
        }
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

      expect(result.success).to be(false)
      expect(result.disposition).to eq("blocked")
      expect(result.critical_findings.map { |finding| finding.fetch("summary") }).to include(
        "refactoring_assessment.disposition must be one of none, include_child, defer_follow_up, blocked_by_design_debt, needs_clarification"
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

  it "treats a valid no_action proposal as eligible for the next gate" do
    Dir.mktmpdir do |dir|
      proposal_path = File.join(dir, "proposal.json")
      File.write(proposal_path, JSON.generate(
        "success" => true,
        "proposal_fingerprint" => "abc123",
        "proposal" => {
          "proposal_fingerprint" => "abc123",
          "outcome" => "no_action",
          "children" => [],
          "reason" => "The requested behavior already exists."
        }
      ))
      process_runner = lambda do |_command, env:, **|
        File.write(env.fetch("A2O_DECOMPOSITION_REVIEW_RESULT_PATH"), JSON.generate("summary" => "eligible", "findings" => []))
        ["", "", FakeReviewStatus.new(true, 0)]
      end

      result = described_class.new(storage_dir: dir, process_runner: process_runner).call(
        task: task,
        project_surface: project_surface([["reviewer"]]),
        proposal_evidence_path: proposal_path
      )

      expect(result.success).to be(true)
      expect(result.disposition).to eq("eligible")
    end
  end

  it "treats a valid needs_clarification proposal as eligible for the next gate" do
    Dir.mktmpdir do |dir|
      proposal_path = File.join(dir, "proposal.json")
      File.write(proposal_path, JSON.generate(
        "success" => true,
        "proposal_fingerprint" => "abc123",
        "proposal" => {
          "proposal_fingerprint" => "abc123",
          "outcome" => "needs_clarification",
          "children" => [],
          "reason" => "The target audience is unclear.",
          "questions" => ["Which user role should receive this?"]
        }
      ))
      process_runner = lambda do |_command, env:, **|
        File.write(env.fetch("A2O_DECOMPOSITION_REVIEW_RESULT_PATH"), JSON.generate("summary" => "eligible", "findings" => []))
        ["", "", FakeReviewStatus.new(true, 0)]
      end

      result = described_class.new(storage_dir: dir, process_runner: process_runner).call(
        task: task,
        project_surface: project_surface([["reviewer"]]),
        proposal_evidence_path: proposal_path
      )

      expect(result.success).to be(true)
      expect(result.disposition).to eq("eligible")
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
