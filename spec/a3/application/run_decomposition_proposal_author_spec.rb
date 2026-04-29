# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe A3::Application::RunDecompositionProposalAuthor do
  FakeAuthorStatus = Struct.new(:success?, :exitstatus)

  let(:task) do
    A3::Domain::Task.new(
      ref: "A3-v2#5300",
      kind: :single,
      edit_scope: [:repo_alpha],
      status: :todo,
      labels: ["trigger:investigate"],
      priority: 3,
      external_task_id: 5300,
      blocking_task_refs: ["A3-v2#5299"]
    )
  end

  def project_surface(command: ["author-proposal", "--json"], prompt_config: A3::Domain::ProjectPromptConfig.empty)
    A3::Domain::ProjectSurface.new(
      implementation_skill: "skills/implementation.md",
      review_skill: "skills/review.md",
      verification_commands: [],
      remediation_commands: [],
      workspace_hook: nil,
      decomposition_author_command: command,
      prompt_config: prompt_config
    )
  end

  def valid_author_result
    {
      "parent_update" => { "body_append" => "Split into child tasks." },
      "children" => [
        {
          "title" => "Add routing",
          "body" => "Route investigate tasks into decomposition.",
          "acceptance_criteria" => ["trigger:investigate is selected separately"],
          "labels" => ["trigger:auto-implement"],
          "priority" => 3,
          "verification_level" => "unit",
          "depends_on" => [],
          "boundary" => "scheduler routing",
          "rationale" => "This is the smallest scheduler boundary."
        },
        {
          "title" => "Add proposal review",
          "body" => "Review generated child-ticket drafts.",
          "acceptance_criteria" => ["critical findings block creation"],
          "labels" => [],
          "priority" => 2,
          "verification_level" => "unit",
          "depends_on" => ["Add routing"],
          "boundary" => "proposal review gate",
          "rationale" => "Review should be separate from authoring."
        }
      ],
      "unresolved_questions" => ["Should auto creation be enabled by default?"],
      "rationale" => "Separate scheduler, author, and review concerns."
    }
  end

  it "runs the project author command, normalizes a proposal draft, and persists evidence" do
    Dir.mktmpdir do |dir|
      investigation = {
        "summary" => "Need decomposition",
        "affected_files" => ["lib/a3/application/plan_next_decomposition_task.rb"]
      }
      captured = {}
      process_runner = lambda do |command, chdir:, env:|
        captured[:command] = command
        captured[:chdir] = chdir
        captured[:env] = env
        File.write(env.fetch("A2O_DECOMPOSITION_AUTHOR_RESULT_PATH"), JSON.generate(valid_author_result))
        ["out", "", FakeAuthorStatus.new(true, 0)]
      end

      result = described_class.new(
        storage_dir: dir,
        process_runner: process_runner,
        clock: -> { Time.utc(2026, 4, 26, 4, 0, 0) }
      ).call(
        task: task,
        project_surface: project_surface,
        investigation_evidence: investigation
      )

      expect(result.success).to be(true)
      expect(result.summary).to match(/proposal [0-9a-f]{64} with 2 child drafts/)
      expect(result.source_ticket_summary).to include("Proposal fingerprint:")
      expect(result.source_ticket_summary).to include("Child drafts: 2")
      expect(result.source_ticket_summary_published).to be(false)
      expect(result.proposal_fingerprint).to match(/\A[0-9a-f]{64}\z/)
      expect(captured.fetch(:command)).to eq(["author-proposal", "--json"])
      expect(captured.fetch(:chdir)).to eq(result.workspace_root)
      expect(result.workspace_root).to start_with(File.join(dir, "decomposition-workspaces", "A3-v2-5300"))
      expect(captured.fetch(:env)).to include(
        "A2O_DECOMPOSITION_AUTHOR_REQUEST_PATH" => result.request_path,
        "A2O_DECOMPOSITION_AUTHOR_RESULT_PATH" => result.result_path,
        "A2O_WORKSPACE_ROOT" => result.workspace_root
      )

      request = JSON.parse(File.read(result.request_path))
      expect(request).to include(
        "task_ref" => "A3-v2#5300",
        "labels" => ["trigger:investigate"],
        "investigation_evidence" => investigation
      )

      proposal = result.proposal
      expect(proposal).to include(
        "source_ticket_ref" => "A3-v2#5300",
        "unresolved_questions" => ["Should auto creation be enabled by default?"]
      )
      expect(proposal.fetch("children").map { |child| child.fetch("child_key") }).to all(match(/\A[0-9a-f]{24}\z/))
      expect(proposal.fetch("children").map { |child| child.fetch("title") }).to eq(["Add routing", "Add proposal review"])

      evidence = JSON.parse(File.read(result.evidence_path))
      expect(evidence).to include(
        "task_ref" => "A3-v2#5300",
        "phase" => "proposal",
        "success" => true,
        "source_ticket_summary" => result.source_ticket_summary,
        "proposal_fingerprint" => result.proposal_fingerprint
      )
      expect(evidence.fetch("proposal").fetch("children").size).to eq(2)
    end
  end

  it "passes decomposition child draft templates to the proposal author request" do
    Dir.mktmpdir do |dir|
      scoped_task = A3::Domain::Task.new(
        ref: "A3-v2#5300",
        kind: :single,
        edit_scope: [:repo_alpha],
        status: :todo,
        labels: ["trigger:investigate"],
        priority: 3,
        external_task_id: 5300
      )
      prompt_config = A3::Domain::ProjectPromptConfig.new(
        system_document: prompt_document("prompts/system.md", "system guidance"),
        phases: {
          "decomposition" => A3::Domain::ProjectPromptConfig::PhaseConfig.new(
            prompt_document: prompt_document("prompts/decomposition.md", "decomposition guidance"),
            skill_documents: [prompt_document("skills/ticket-splitting.md", "split carefully")],
            child_draft_template_document: prompt_document("prompts/child-template.md", "Base child template")
          )
        },
        repo_slots: {
          "repo_alpha" => {
            "decomposition" => A3::Domain::ProjectPromptConfig::PhaseConfig.new(
              child_draft_template_document: prompt_document("prompts/repo-alpha-child-template.md", "Repo alpha template")
            )
          }
        }
      )
      process_runner = lambda do |_command, env:, **|
        File.write(env.fetch("A2O_DECOMPOSITION_AUTHOR_RESULT_PATH"), JSON.generate(valid_author_result))
        ["", "", FakeAuthorStatus.new(true, 0)]
      end

      result = described_class.new(storage_dir: dir, process_runner: process_runner).call(
        task: scoped_task,
        project_surface: project_surface(prompt_config: prompt_config),
        investigation_evidence: { "summary" => "Need split" }
      )

      request = JSON.parse(File.read(result.request_path))
      project_prompt = request.fetch("project_prompt")
      expect(project_prompt.fetch("profile")).to eq("decomposition")
      expect(project_prompt.fetch("layers").map { |layer| layer.fetch("kind") }).to include(
        "project_system_prompt",
        "project_phase_prompt",
        "project_phase_skill",
        "decomposition_child_draft_template",
        "repo_slot_decomposition_child_draft_template"
      )
      expect(project_prompt.fetch("layers").map { |layer| layer.fetch("title") }).to include(
        "prompts/child-template.md",
        "repo_alpha:prompts/repo-alpha-child-template.md"
      )
      expect(project_prompt.fetch("composed_instruction")).to include("Base child template")
      expect(project_prompt.fetch("composed_instruction")).to include("Repo alpha template")
      evidence = JSON.parse(File.read(result.evidence_path))
      expect(evidence.fetch("request").fetch("project_prompt")).to eq(project_prompt)
    end
  end

  it "generates a stable proposal fingerprint from investigation evidence and child drafts" do
    Dir.mktmpdir do |dir|
      process_runner = lambda do |_command, env:, **|
        File.write(env.fetch("A2O_DECOMPOSITION_AUTHOR_RESULT_PATH"), JSON.generate(valid_author_result))
        ["", "", FakeAuthorStatus.new(true, 0)]
      end
      use_case = described_class.new(storage_dir: dir, process_runner: process_runner)

      first = use_case.call(task: task, project_surface: project_surface, investigation_evidence: { "summary" => "same" })
      second = use_case.call(task: task, project_surface: project_surface, investigation_evidence: { "summary" => "same" })
      third = use_case.call(task: task, project_surface: project_surface, investigation_evidence: { "summary" => "changed" })

      expect(first.proposal_fingerprint).to eq(second.proposal_fingerprint)
      expect(first.proposal_fingerprint).not_to eq(third.proposal_fingerprint)
    end
  end

  it "keeps child keys stable when child draft order changes" do
    Dir.mktmpdir do |dir|
      first_payload = valid_author_result
      second_payload = valid_author_result.merge("children" => valid_author_result.fetch("children").reverse)
      calls = [first_payload, second_payload]
      process_runner = lambda do |_command, env:, **|
        File.write(env.fetch("A2O_DECOMPOSITION_AUTHOR_RESULT_PATH"), JSON.generate(calls.shift))
        ["", "", FakeAuthorStatus.new(true, 0)]
      end
      use_case = described_class.new(storage_dir: dir, process_runner: process_runner)

      first = use_case.call(task: task, project_surface: project_surface, investigation_evidence: { "summary" => "same" })
      second = use_case.call(task: task, project_surface: project_surface, investigation_evidence: { "summary" => "same" })

      first_keys = first.proposal.fetch("children").map { |child| [child.fetch("title"), child.fetch("child_key")] }.to_h
      second_keys = second.proposal.fetch("children").map { |child| [child.fetch("title"), child.fetch("child_key")] }.to_h
      expect(second_keys).to eq(first_keys)
    end
  end

  it "preserves boolean false when deriving proposal fingerprints" do
    Dir.mktmpdir do |dir|
      process_runner = lambda do |_command, env:, **|
        File.write(env.fetch("A2O_DECOMPOSITION_AUTHOR_RESULT_PATH"), JSON.generate(valid_author_result.merge("auto_create" => false)))
        ["", "", FakeAuthorStatus.new(true, 0)]
      end
      use_case = described_class.new(storage_dir: dir, process_runner: process_runner)

      false_result = use_case.call(task: task, project_surface: project_surface, investigation_evidence: { "ready" => false })
      nil_result = use_case.call(task: task, project_surface: project_surface, investigation_evidence: { "ready" => nil })

      expect(false_result.proposal_fingerprint).not_to eq(nil_result.proposal_fingerprint)
    end
  end

  it "blocks with evidence when the proposal schema is invalid" do
    Dir.mktmpdir do |dir|
      process_runner = lambda do |_command, env:, **|
        File.write(env.fetch("A2O_DECOMPOSITION_AUTHOR_RESULT_PATH"), JSON.generate("children" => []))
        ["", "", FakeAuthorStatus.new(true, 0)]
      end

      result = described_class.new(storage_dir: dir, process_runner: process_runner).call(
        task: task,
        project_surface: project_surface,
        investigation_evidence: { "summary" => "ok" }
      )

      expect(result.success).to be(false)
      expect(result.summary).to include("children must be a non-empty array")
      expect(result.observed_state).to include("children must be a non-empty array")
      evidence = JSON.parse(File.read(result.evidence_path))
      expect(evidence.fetch("success")).to be(false)
      expect(evidence.fetch("validation_errors")).to include("children must be a non-empty array")
    end
  end

  it "blocks instead of coercing non-array schema fields" do
    Dir.mktmpdir do |dir|
      invalid_payload = valid_author_result.merge(
        "unresolved_questions" => "none",
        "children" => [
          valid_author_result.fetch("children").first.merge(
            "labels" => "trigger:auto-implement",
            "depends_on" => "other"
          )
        ]
      )
      process_runner = lambda do |_command, env:, **|
        File.write(env.fetch("A2O_DECOMPOSITION_AUTHOR_RESULT_PATH"), JSON.generate(invalid_payload))
        ["", "", FakeAuthorStatus.new(true, 0)]
      end

      result = described_class.new(storage_dir: dir, process_runner: process_runner).call(
        task: task,
        project_surface: project_surface,
        investigation_evidence: { "summary" => "ok" }
      )

      expect(result.success).to be(false)
      expect(result.summary).to include("children[0].labels must be an array")
      expect(result.summary).to include("children[0].depends_on must be an array")
      expect(result.summary).to include("unresolved_questions must be an array")
    end
  end

  it "blocks when child drafts omit stable boundaries" do
    Dir.mktmpdir do |dir|
      invalid_payload = valid_author_result.merge(
        "children" => [
          valid_author_result.fetch("children").first.reject { |key, _| key == "boundary" }
        ]
      )
      process_runner = lambda do |_command, env:, **|
        File.write(env.fetch("A2O_DECOMPOSITION_AUTHOR_RESULT_PATH"), JSON.generate(invalid_payload))
        ["", "", FakeAuthorStatus.new(true, 0)]
      end

      result = described_class.new(storage_dir: dir, process_runner: process_runner).call(
        task: task,
        project_surface: project_surface,
        investigation_evidence: { "summary" => "ok" }
      )

      expect(result.success).to be(false)
      expect(result.summary).to include("children[0].boundary must be a non-empty string")
    end
  end

  it "publishes the source-ticket proposal summary when an activity publisher is provided" do
    Dir.mktmpdir do |dir|
      publisher = instance_double(A3::Infra::NullExternalTaskActivityPublisher)
      expect(publisher).to receive(:publish).with(
        task_ref: "A3-v2#5300",
        external_task_id: 5300,
        body: a_string_matching(/Proposal fingerprint:.*Child drafts: 2/m)
      )
      process_runner = lambda do |_command, env:, **|
        File.write(env.fetch("A2O_DECOMPOSITION_AUTHOR_RESULT_PATH"), JSON.generate(valid_author_result))
        ["", "", FakeAuthorStatus.new(true, 0)]
      end

      result = described_class.new(
        storage_dir: dir,
        process_runner: process_runner,
        publish_external_task_activity: publisher
      ).call(
        task: task,
        project_surface: project_surface,
        investigation_evidence: { "summary" => "ok" }
      )

      expect(result.source_ticket_summary_published).to be(true)
    end
  end

  it "resolves relative command paths against the project root" do
    Dir.mktmpdir do |dir|
      project_root = File.join(dir, "project")
      FileUtils.mkdir_p(project_root)
      captured = {}
      process_runner = lambda do |command, env:, **|
        captured[:command] = command
        File.write(env.fetch("A2O_DECOMPOSITION_AUTHOR_RESULT_PATH"), JSON.generate(valid_author_result))
        ["", "", FakeAuthorStatus.new(true, 0)]
      end

      described_class.new(
        storage_dir: dir,
        project_root: project_root,
        process_runner: process_runner
      ).call(
        task: task,
        project_surface: project_surface(command: ["commands/author-proposal.sh", "--json"]),
        investigation_evidence: { "summary" => "ok" }
      )

      expect(captured.fetch(:command)).to eq([File.join(project_root, "commands/author-proposal.sh"), "--json"])
    end
  end

  it "requires a decomposition author command" do
    Dir.mktmpdir do |dir|
      surface = A3::Domain::ProjectSurface.new(
        implementation_skill: "skills/implementation.md",
        review_skill: "skills/review.md",
        verification_commands: [],
        remediation_commands: [],
        workspace_hook: nil
      )

      expect do
        described_class.new(storage_dir: dir).call(task: task, project_surface: surface)
      end.to raise_error(A3::Domain::ConfigurationError, /runtime.decomposition.author.command/)
    end
  end

  def prompt_document(path, content)
    A3::Domain::ProjectPromptConfig::Document.new(
      path: path,
      absolute_path: File.join(Dir.tmpdir, path),
      content: content
    )
  end
end
