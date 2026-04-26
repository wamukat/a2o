# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe A3::Application::RunDecompositionInvestigation do
  FakeStatus = Struct.new(:success?, :exitstatus)

  let(:task) do
    A3::Domain::Task.new(
      ref: "A3-v2#5300",
      kind: :single,
      edit_scope: [:repo_alpha],
      status: :todo,
      labels: ["trigger:investigate"],
      priority: 3,
      blocking_task_refs: ["A3-v2#5299"]
    )
  end

  it "runs the project investigate command in an isolated workspace and persists evidence" do
    Dir.mktmpdir do |dir|
      source_repo = File.join(dir, "repo-source")
      FileUtils.mkdir_p(File.join(source_repo, "lib"))
      File.write(File.join(source_repo, "lib", "a.rb"), "class A; end\n")
      project_surface = A3::Domain::ProjectSurface.new(
        implementation_skill: "skills/implementation.md",
        review_skill: "skills/review.md",
        verification_commands: [],
        remediation_commands: [],
        workspace_hook: nil,
        decomposition_investigate_command: ["investigate", "--json"]
      )
      captured = {}
      process_runner = lambda do |command, chdir:, env:|
        captured[:command] = command
        captured[:chdir] = chdir
        captured[:env] = env
        request = JSON.parse(File.read(env.fetch("A2O_DECOMPOSITION_REQUEST_PATH")))
        captured[:request] = request
        File.write(env.fetch("A2O_DECOMPOSITION_RESULT_PATH"), JSON.generate("summary" => "investigated #{request.fetch('title')}", "affected_files" => ["lib/a.rb"]))
        ["out", "", FakeStatus.new(true, 0)]
      end

      result = nil
      begin
        result = described_class.new(
          storage_dir: dir,
          process_runner: process_runner,
          clock: -> { Time.utc(2026, 4, 26, 3, 0, 0) }
        ).call(
          task: task,
          project_surface: project_surface,
          slot_paths: { repo_alpha: source_repo },
          task_snapshot: {
            "ref" => "A3-v2#5300",
            "title" => "Split workflow",
            "description" => "Investigate decomposition requirements.",
            "status" => "To do",
            "labels" => ["trigger:investigate"]
          }
        )

        expect(result.success).to be(true)
        expect(result.summary).to eq("investigated Split workflow")
        expect(captured.fetch(:command)).to eq(["investigate", "--json"])
        expect(captured.fetch(:chdir)).to eq(result.workspace_root)
        expect(result.workspace_root).to start_with(File.join(dir, "decomposition-workspaces", "A3-v2-5300"))
        expect(captured.fetch(:env)).to include(
          "A2O_DECOMPOSITION_REQUEST_PATH" => result.request_path,
          "A2O_DECOMPOSITION_RESULT_PATH" => result.result_path,
          "A2O_WORKSPACE_ROOT" => result.workspace_root
        )

        request = JSON.parse(File.read(result.request_path))
        isolated_repo = request.fetch("slot_paths").fetch("repo_alpha")
        expect(request).to include(
          "task_ref" => "A3-v2#5300",
          "title" => "Split workflow",
          "description" => "Investigate decomposition requirements.",
          "labels" => ["trigger:investigate"]
        )
        expect(isolated_repo).not_to eq(source_repo)
        expect(isolated_repo).to start_with(result.workspace_root)
        expect(File.read(File.join(isolated_repo, "lib", "a.rb"))).to eq("class A; end\n")
        expect(File.writable?(isolated_repo)).to be(false)

        evidence = JSON.parse(File.read(result.evidence_path))
        expect(evidence).to include(
          "task_ref" => "A3-v2#5300",
          "phase" => "investigation",
          "success" => true,
          "summary" => "investigated Split workflow"
        )
        expect(evidence.fetch("workspace_root")).to eq(result.workspace_root)
      ensure
        FileUtils.chmod_R("u+w", result.workspace_root) if result
      end
    end
  end

  it "includes previous evidence summary in rerun requests" do
    Dir.mktmpdir do |dir|
      previous_dir = File.join(dir, "decomposition-evidence", "A3-v2-5300")
      FileUtils.mkdir_p(previous_dir)
      previous_path = File.join(previous_dir, "investigation.json")
      File.write(previous_path, JSON.generate("summary" => "previous investigation"))
      project_surface = A3::Domain::ProjectSurface.new(
        implementation_skill: "skills/implementation.md",
        review_skill: "skills/review.md",
        verification_commands: [],
        remediation_commands: [],
        workspace_hook: nil,
        decomposition_investigate_command: ["investigate"]
      )
      captured = {}
      process_runner = lambda do |_command, env:, **|
        captured[:request] = JSON.parse(File.read(env.fetch("A2O_DECOMPOSITION_REQUEST_PATH")))
        File.write(env.fetch("A2O_DECOMPOSITION_RESULT_PATH"), JSON.generate("summary" => "ok"))
        ["", "", FakeStatus.new(true, 0)]
      end

      described_class.new(storage_dir: dir, process_runner: process_runner).call(
        task: task,
        project_surface: project_surface,
        previous_evidence_path: previous_path
      )

      expect(captured.fetch(:request)).to include(
        "previous_evidence_path" => previous_path,
        "previous_evidence_summary" => "previous investigation"
      )
    end
  end

  it "resolves relative command paths against the project root" do
    Dir.mktmpdir do |dir|
      project_root = File.join(dir, "project")
      FileUtils.mkdir_p(project_root)
      project_surface = A3::Domain::ProjectSurface.new(
        implementation_skill: "skills/implementation.md",
        review_skill: "skills/review.md",
        verification_commands: [],
        remediation_commands: [],
        workspace_hook: nil,
        decomposition_investigate_command: ["commands/investigate.sh", "--json"]
      )
      captured = {}
      process_runner = lambda do |command, env:, **|
        captured[:command] = command
        File.write(env.fetch("A2O_DECOMPOSITION_RESULT_PATH"), JSON.generate("summary" => "ok"))
        ["", "", FakeStatus.new(true, 0)]
      end

      described_class.new(
        storage_dir: dir,
        project_root: project_root,
        process_runner: process_runner
      ).call(task: task, project_surface: project_surface)

      expect(captured.fetch(:command)).to eq([File.join(project_root, "commands/investigate.sh"), "--json"])
    end
  end

  it "blocks with actionable evidence when the command exits non-zero" do
    Dir.mktmpdir do |dir|
      project_surface = A3::Domain::ProjectSurface.new(
        implementation_skill: "skills/implementation.md",
        review_skill: "skills/review.md",
        verification_commands: [],
        remediation_commands: [],
        workspace_hook: nil,
        decomposition_investigate_command: ["investigate"]
      )
      process_runner = lambda do |_command, env:, **|
        File.write(env.fetch("A2O_DECOMPOSITION_RESULT_PATH"), JSON.generate("summary" => "partial"))
        ["", "boom", FakeStatus.new(false, 17)]
      end

      result = described_class.new(storage_dir: dir, process_runner: process_runner).call(
        task: task,
        project_surface: project_surface
      )

      expect(result.success).to be(false)
      expect(result.summary).to eq("investigate failed with exit 17")
      expect(result.failing_command).to eq("investigate")
      expect(result.observed_state).to eq("exit 17")
      evidence = JSON.parse(File.read(result.evidence_path))
      expect(evidence.fetch("success")).to be(false)
      expect(evidence.fetch("stderr")).to eq("boom")
    end
  end

  it "blocks when the result JSON is missing or invalid" do
    Dir.mktmpdir do |dir|
      project_surface = A3::Domain::ProjectSurface.new(
        implementation_skill: "skills/implementation.md",
        review_skill: "skills/review.md",
        verification_commands: [],
        remediation_commands: [],
        workspace_hook: nil,
        decomposition_investigate_command: ["investigate"]
      )
      process_runner = lambda do |_command, env:, **|
        File.write(env.fetch("A2O_DECOMPOSITION_RESULT_PATH"), "not json")
        ["", "", FakeStatus.new(true, 0)]
      end

      result = described_class.new(storage_dir: dir, process_runner: process_runner).call(
        task: task,
        project_surface: project_surface
      )

      expect(result.success).to be(false)
      expect(result.summary).to eq("investigation result JSON is missing or invalid")
      expect(result.observed_state).to eq("missing_or_invalid_result_json")
    end
  end

  it "persists failure evidence when the command cannot launch" do
    Dir.mktmpdir do |dir|
      project_surface = A3::Domain::ProjectSurface.new(
        implementation_skill: "skills/implementation.md",
        review_skill: "skills/review.md",
        verification_commands: [],
        remediation_commands: [],
        workspace_hook: nil,
        decomposition_investigate_command: ["missing-investigate"]
      )
      process_runner = lambda do |_command, **|
        raise Errno::ENOENT, "missing-investigate"
      end

      result = described_class.new(storage_dir: dir, process_runner: process_runner).call(
        task: task,
        project_surface: project_surface
      )

      expect(result.success).to be(false)
      expect(result.summary).to include("failed to launch")
      expect(result.observed_state).to include("launch_error")
      evidence = JSON.parse(File.read(result.evidence_path))
      expect(evidence.fetch("success")).to be(false)
      expect(evidence.fetch("stderr")).to include("missing-investigate")
    end
  end

  it "uses a unique workspace for each investigation run" do
    Dir.mktmpdir do |dir|
      project_surface = A3::Domain::ProjectSurface.new(
        implementation_skill: "skills/implementation.md",
        review_skill: "skills/review.md",
        verification_commands: [],
        remediation_commands: [],
        workspace_hook: nil,
        decomposition_investigate_command: ["investigate"]
      )
      process_runner = lambda do |_command, env:, **|
        File.write(env.fetch("A2O_DECOMPOSITION_RESULT_PATH"), JSON.generate("summary" => "ok"))
        ["", "", FakeStatus.new(true, 0)]
      end
      use_case = described_class.new(
        storage_dir: dir,
        process_runner: process_runner,
        clock: -> { Time.utc(2026, 4, 26, 3, 0, 0) }
      )

      first = use_case.call(task: task, project_surface: project_surface)
      second = use_case.call(task: task, project_surface: project_surface)

      expect(first.workspace_root).not_to eq(second.workspace_root)
      expect(first.result_path).not_to eq(second.result_path)
    end
  end

  it "requires a decomposition investigate command" do
    Dir.mktmpdir do |dir|
      project_surface = A3::Domain::ProjectSurface.new(
        implementation_skill: "skills/implementation.md",
        review_skill: "skills/review.md",
        verification_commands: [],
        remediation_commands: [],
        workspace_hook: nil
      )

      expect do
        described_class.new(storage_dir: dir).call(task: task, project_surface: project_surface)
      end.to raise_error(A3::Domain::ConfigurationError, /runtime.decomposition.investigate.command/)
    end
  end
end
