# frozen_string_literal: true

require "tmpdir"
require "rbconfig"

RSpec.describe A3::CLI do
  def with_env(values)
    original = {}
    values.each do |key, value|
      original[key] = ENV.key?(key) ? ENV[key] : :__missing__
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    original.each do |key, value|
      value == :__missing__ ? ENV.delete(key) : ENV[key] = value
    end
  end

  it "responds to start" do
    expect(described_class).to respond_to(:start)
  end

  it "prints public A2O usage for --help" do
    out = StringIO.new

    described_class.start(["--help"], out: out)

    expect(out.string).to include("A2O runtime container CLI")
    expect(out.string).to include("This help is for the runtime container entrypoint")
    expect(out.string).to include("usage:")
    expect(out.string).to include("a2o host install")
    expect(out.string).to include(".work/a2o/bin/a2o project template --help")
    expect(out.string).not_to include("A3 CLI placeholder")
  end

  it "routes known commands through the command dispatcher" do
    out = StringIO.new
    allow(described_class).to receive(:handle_show_task)

    described_class.start(
      ["show-task", "A3-v2#3025"],
      out: out
    )

    expect(described_class).to have_received(:handle_show_task).with(
      ["A3-v2#3025"],
      out: out,
      run_id_generator: kind_of(Proc),
      command_runner: an_instance_of(A3::Infra::LocalCommandRunner),
      merge_runner: an_instance_of(A3::Infra::DisabledMergeRunner)
    )
  end

  it "logs agent server lifecycle and fatal errors to stderr" do
    Dir.mktmpdir do |dir|
      out = StringIO.new
      server = instance_double(A3::Infra::AgentHttpPullServer)
      allow(A3::Infra::AgentHttpPullServer).to receive(:new).and_return(server)
      allow(server).to receive(:start).and_raise(RuntimeError, "server exploded")

      expect do
        expect do
          described_class.handle_agent_server(
            ["--storage-dir", dir, "--host", "127.0.0.1", "--port", "0"],
            out: out
          )
        end.to raise_error(RuntimeError, "server exploded")
      end.to output(
        /agent_server_start host=127\.0\.0\.1 port=0 .* pid=\d+.*agent_server_fatal_error class=RuntimeError message=server exploded pid=\d+.*agent_server_fatal_backtrace .*agent_server_exit pid=\d+/m
      ).to_stderr

      expect(out.string).to include("agent server listening on 127.0.0.1:0")
    end
  end

  it "passes parsed skill feedback list filters to the application service" do
    out = StringIO.new
    service = instance_double(A3::Application::ListSkillFeedback)
    entry = A3::Application::ListSkillFeedback::Entry.new(
      task_ref: "A2O#204",
      run_ref: "run-1",
      phase: :implementation,
      category: "missing_context",
      summary: "Add setup guidance.",
      target: "project_skill",
      state: "new"
    )
    allow(service).to receive(:call).with(state: "new", target: "project_skill", group: false).and_return([entry])
    allow(described_class).to receive(:with_storage_container).and_yield(
      { state: "new", target: "project_skill", group: false },
      { list_skill_feedback: service }
    )

    described_class.handle_skill_feedback_list(
      ["--state", "new", "--target", "project_skill"],
      out: out,
      run_id_generator: -> { "run-1" },
      command_runner: A3::Infra::LocalCommandRunner.new,
      merge_runner: A3::Infra::DisabledMergeRunner.new
    )

    expect(out.string).to include("skill_feedback task=A2O#204 run=run-1 phase=implementation category=missing_context target=project_skill state=new")
  end

  it "prints task metrics list as JSON and CSV" do
    Dir.mktmpdir do |dir|
      repository = A3::Infra::JsonTaskMetricsRepository.new(File.join(dir, "task_metrics.json"))
      repository.save(
        A3::Domain::TaskMetricsRecord.new(
          task_ref: "A2O#101",
          parent_ref: "A2O#100",
          timestamp: "2026-04-27T01:00:00Z",
          code_changes: { "lines_added" => 10 },
          tests: { "passed_count" => 3 }
        )
      )

      json_out = StringIO.new
      described_class.start(["metrics", "list", "--storage-dir", dir, "--format", "json"], out: json_out)

      expect(JSON.parse(json_out.string)).to contain_exactly(
        hash_including(
          "task_ref" => "A2O#101",
          "parent_ref" => "A2O#100",
          "code_changes" => { "lines_added" => 10 },
          "tests" => { "passed_count" => 3 }
        )
      )

      csv_out = StringIO.new
      described_class.start(["metrics", "list", "--storage-dir", dir, "--format", "csv"], out: csv_out)

      rows = CSV.parse(csv_out.string, headers: true)
      expect(rows.first["task_ref"]).to eq("A2O#101")
      expect(rows.first["parent_ref"]).to eq("A2O#100")
      expect(JSON.parse(rows.first["code_changes"])).to eq("lines_added" => 10)
    end
  end

  it "prints task metrics summary by task and by parent" do
    Dir.mktmpdir do |dir|
      repository = A3::Infra::JsonTaskMetricsRepository.new(File.join(dir, "task_metrics.json"))
      repository.save(
        A3::Domain::TaskMetricsRecord.new(
          task_ref: "A2O#101",
          parent_ref: "A2O#100",
          timestamp: "2026-04-27T01:00:00Z",
          code_changes: { "lines_added" => 10 },
          tests: { "passed_count" => 3 }
        )
      )
      repository.save(
        A3::Domain::TaskMetricsRecord.new(
          task_ref: "A2O#102",
          parent_ref: "A2O#100",
          timestamp: "2026-04-27T02:00:00Z",
          code_changes: { "lines_added" => 5 },
          tests: { "passed_count" => 4, "failed_count" => 1 }
        )
      )

      task_out = StringIO.new
      described_class.start(["metrics", "summary", "--storage-dir", dir], out: task_out)

      expect(task_out.string).to include("metrics_summary group_key=A2O#101")
      expect(task_out.string).to include("metrics_summary group_key=A2O#102")

      parent_out = StringIO.new
      described_class.start(["metrics", "summary", "--storage-dir", dir, "--group-by", "parent", "--format", "json"], out: parent_out)

      expect(JSON.parse(parent_out.string)).to contain_exactly(
        hash_including(
          "group_key" => "A2O#100",
          "record_count" => 2,
          "task_count" => 2,
          "lines_added" => 15,
          "tests_passed" => 7,
          "tests_failed" => 1
        )
      )
    end
  end

  it "prints task metrics trends without changing list or summary output" do
    Dir.mktmpdir do |dir|
      repository = A3::Infra::JsonTaskMetricsRepository.new(File.join(dir, "task_metrics.json"))
      repository.save(
        A3::Domain::TaskMetricsRecord.new(
          task_ref: "A2O#101",
          parent_ref: "A2O#100",
          timestamp: "2026-04-27T01:00:00Z",
          code_changes: { "lines_added" => 10 },
          tests: { "passed_count" => 9, "failed_count" => 1 },
          coverage: { "line_percent" => 80.0 },
          timing: { "verification_seconds" => 30, "total_seconds" => 120, "rework_count" => 1 },
          cost: { "tokens_input" => 3000, "tokens_output" => 500 }
        )
      )
      repository.save(
        A3::Domain::TaskMetricsRecord.new(
          task_ref: "A2O#102",
          parent_ref: "A2O#100",
          timestamp: "2026-04-27T02:00:00Z",
          code_changes: { "lines_added" => 5 },
          tests: { "passed_count" => 5, "failed_count" => 0 },
          coverage: { "line_percent" => 82.0 },
          timing: { "verification_seconds" => 10, "total_seconds" => 60 },
          cost: { "tokens_input" => 1000, "tokens_output" => 250 }
        )
      )

      text_out = StringIO.new
      described_class.start(["metrics", "trends", "--storage-dir", dir], out: text_out)

      expect(text_out.string).to include("metrics_trends group_key=all")
      expect(text_out.string).to include("rework_count=1")
      expect(text_out.string).to include('unsupported_indicators=["blocked_rate"]')

      json_out = StringIO.new
      described_class.start(["metrics", "trends", "--storage-dir", dir, "--group-by", "parent", "--format", "json"], out: json_out)

      expect(JSON.parse(json_out.string)).to contain_exactly(
        hash_including(
          "group_key" => "A2O#100",
          "record_count" => 2,
          "task_count" => 2,
          "lines_added" => 15,
          "tests_total" => 15,
          "tests_failed" => 1,
          "test_failure_rate" => (1.0 / 15.0),
          "avg_verification_seconds" => 20.0,
          "avg_total_seconds" => 90.0,
          "rework_count" => 1,
          "rework_rate" => 0.5,
          "tokens_input" => 4000,
          "tokens_output" => 750,
          "tokens_per_line_added" => (4750.0 / 15.0),
          "line_coverage_delta" => 2.0,
          "unsupported_indicators" => ["blocked_rate"]
        )
      )
    end
  end

  it "routes manifest-driven runtime commands through the shared runtime session helper" do
    out = StringIO.new
    session = Struct.new(:options, :container, :project_context, :project_surface, keyword_init: true).new(
      options: {
        task_ref: "A3-v2#3025",
        run_ref: "run-1",
        manifest_path: "/tmp/project.yaml",
        preset_dir: "/tmp/presets"
      },
      container: {
        build_merge_plan: instance_double(
          A3::Application::BuildMergePlan,
          call: Struct.new(:merge_plan).new(
            Struct.new(:merge_source, :integration_target, :merge_policy, :merge_slots).new(
              Struct.new(:source_ref).new("refs/heads/a2o/work/A3-v2-3025"),
              Struct.new(:target_ref).new("refs/heads/a2o/parent/A3-v2#3022"),
              :ff_only,
              [:repo_alpha]
            )
          )
        )
      },
      project_context: Object.new,
      project_surface: Object.new
    )
    allow(described_class).to receive(:with_runtime_session).and_yield(session)

    described_class.start(
      ["show-merge-plan", "A3-v2#3025", "run-1", "/tmp/project.yaml", "--preset-dir", "/tmp/presets"],
      out: out
    )

    expect(described_class).to have_received(:with_runtime_session)
    expect(out.string).to include("merge_source=refs/heads/a2o/work/A3-v2-3025")
  end

  it "runs decomposition proposal author from a stored task and project manifest" do
    Dir.mktmpdir do |dir|
      commands_dir = File.join(dir, "commands")
      FileUtils.mkdir_p(commands_dir)
      author_path = File.join(commands_dir, "author-proposal.rb")
      File.write(
        author_path,
        <<~RUBY
          #!#{RbConfig.ruby}
          require "json"
          File.write(
            ENV.fetch("A2O_DECOMPOSITION_AUTHOR_RESULT_PATH"),
            JSON.generate(
              "children" => [
                {
                  "title" => "Add routing",
                  "body" => "Route investigate tasks.",
                  "acceptance_criteria" => ["routing is tested"],
                  "labels" => [],
                  "depends_on" => [],
                  "boundary" => "scheduler routing",
                  "rationale" => "Scheduler routing is the first boundary."
                }
              ],
              "unresolved_questions" => []
            )
          )
        RUBY
      )
      FileUtils.chmod(0o755, author_path)
      manifest_path = File.join(dir, "project.yaml")
      File.write(
        manifest_path,
        <<~YAML
          schema_version: 1
          runtime:
            decomposition:
              author:
                command: ["commands/author-proposal.rb"]
            phases:
              implementation:
                skill: skills/implementation/base.md
              review:
                skill: skills/review/default.md
              merge:
                policy: ff_only
                target_ref: refs/heads/main
        YAML
      )
      task_repository = A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#5300",
          kind: :single,
          edit_scope: [:repo_alpha],
          status: :todo,
          labels: ["trigger:investigate"]
        )
      )
      investigation_dir = File.join(dir, "decomposition-evidence", "A3-v2-5300")
      FileUtils.mkdir_p(investigation_dir)
      File.write(File.join(investigation_dir, "investigation.json"), JSON.generate("summary" => "investigated"))

      out = StringIO.new
      described_class.start(
        [
          "run-decomposition-proposal-author",
          "A3-v2#5300",
          manifest_path,
          "--storage-dir", dir
        ],
        out: out
      )

      expect(out.string).to include("decomposition proposal A3-v2#5300 success=true")
      expect(out.string).to include("proposal_fingerprint=")
      evidence = JSON.parse(File.read(File.join(dir, "decomposition-evidence", "A3-v2-5300", "proposal.json")))
      expect(evidence.fetch("success")).to be(true)
      expect(evidence.fetch("proposal").fetch("children").first.fetch("title")).to eq("Add routing")
    end
  end

  it "passes custom child creation evidence paths to the application service" do
    out = StringIO.new
    service = instance_double(A3::Application::RunDecompositionChildCreation)
    result = A3::Application::RunDecompositionChildCreation::Result.new(
      success: nil,
      status: "gate_closed",
      summary: "decomposition child creation gate is closed",
      child_refs: [],
      child_keys: [],
      evidence_path: "/tmp/child-creation.json"
    )
    task = A3::Domain::Task.new(ref: "A3-v2#5300", kind: :single, edit_scope: [:repo_alpha])
    repository = instance_double(A3::Infra::JsonTaskRepository, fetch: task)
    allow(described_class).to receive(:build_watch_summary_repositories).and_return(task_repository: repository)
    allow(A3::Application::RunDecompositionChildCreation).to receive(:new).and_return(service)
    allow(service).to receive(:call).and_return(result)

    described_class.start(
      [
        "run-decomposition-child-creation",
        "A3-v2#5300",
        "--storage-dir", "/tmp/a2o-state",
        "--proposal-evidence-path", "/tmp/custom-proposal.json",
        "--review-evidence-path", "/tmp/custom-review.json"
      ],
      out: out
    )

    expect(service).to have_received(:call).with(
      task: task,
      gate: false,
      proposal_evidence_path: "/tmp/custom-proposal.json",
      review_evidence_path: "/tmp/custom-review.json"
    )
    expect(out.string).to include("decomposition child creation A3-v2#5300 status=gate_closed")
    expect(out.string).to include("child_creation_result=not_attempted")
    expect(out.string).to include("status=gate_closed")
    expect(out.string).not_to include("success=")
  end

  it "automatically creates draft children after an eligible proposal review when Kanban writing is configured" do
    out = StringIO.new
    task = A3::Domain::Task.new(ref: "A3-v2#5300", kind: :single, edit_scope: [:repo_alpha], labels: ["trigger:investigate"])
    session = Struct.new(:options, :container, :project_context, :project_surface, keyword_init: true).new(
      options: {
        task_ref: "A3-v2#5300",
        storage_dir: "/tmp/a2o-state",
        manifest_path: "/tmp/project.yaml",
        proposal_evidence_path: "/tmp/proposal.json",
        kanban_command: "kanban",
        kanban_command_args: ["--json"],
        kanban_project: "A3-v2",
        kanban_working_dir: "/tmp"
      },
      container: { external_task_activity_publisher: A3::Infra::NullExternalTaskActivityPublisher.new },
      project_context: Object.new,
      project_surface: Object.new
    )
    review_result = A3::Application::RunDecompositionProposalReview::Result.new(
      success: true,
      summary: "proposal review eligible for next gate",
      disposition: "eligible",
      critical_findings: [],
      review_results: [],
      evidence_path: "/tmp/proposal-review.json"
    )
    child_result = A3::Application::RunDecompositionChildCreation::Result.new(
      success: true,
      status: "created",
      summary: "created or reconciled 1 decomposition child ticket(s)",
      child_refs: ["A3-v2#5301"],
      child_keys: ["child-key-1"],
      evidence_path: "/tmp/child-creation.json"
    )
    review_service = instance_double(A3::Application::RunDecompositionProposalReview, call: review_result)
    child_service = instance_double(A3::Application::RunDecompositionChildCreation)
    writer = instance_double(A3::Infra::KanbanCliProposalChildWriter)
    allow(described_class).to receive(:with_runtime_session).and_yield(session)
    allow(described_class).to receive(:resolve_direct_task).and_return(task)
    allow(A3::Application::RunDecompositionProposalReview).to receive(:new).and_return(review_service)
    expect(A3::Infra::KanbanCliProposalChildWriter).to receive(:new).with(
      command_argv: ["kanban", "--json"],
      project: "A3-v2",
      working_dir: "/tmp",
      mode: :draft
    ).and_return(writer)
    expect(A3::Application::RunDecompositionChildCreation).to receive(:new).with(
      storage_dir: "/tmp/a2o-state",
      child_writer: writer,
      publish_external_task_activity: an_instance_of(A3::Infra::KanbanCliTaskActivityPublisher)
    ).and_return(child_service)
    expect(child_service).to receive(:call).with(
      task: task,
      gate: true,
      proposal_evidence_path: "/tmp/proposal.json",
      review_evidence_path: "/tmp/proposal-review.json"
    ).and_return(child_result)

    described_class.start(["run-decomposition-proposal-review", "A3-v2#5300", "/tmp/project.yaml"], out: out)

    expect(out.string).to include("decomposition proposal review A3-v2#5300 disposition=eligible success=true")
    expect(out.string).to include("decomposition draft child creation A3-v2#5300 success=true")
    expect(out.string).to include("draft_child_refs=A3-v2#5301")
  end

  it "does not attempt automatic draft creation when proposal review is not eligible" do
    out = StringIO.new
    task = A3::Domain::Task.new(ref: "A3-v2#5300", kind: :single, edit_scope: [:repo_alpha], labels: ["trigger:investigate"])
    session = Struct.new(:options, :container, :project_context, :project_surface, keyword_init: true).new(
      options: {
        task_ref: "A3-v2#5300",
        storage_dir: "/tmp/a2o-state",
        manifest_path: "/tmp/project.yaml",
        proposal_evidence_path: "/tmp/proposal.json",
        kanban_command: "kanban",
        kanban_project: "A3-v2"
      },
      container: { external_task_activity_publisher: A3::Infra::NullExternalTaskActivityPublisher.new },
      project_context: Object.new,
      project_surface: Object.new
    )
    review_result = A3::Application::RunDecompositionProposalReview::Result.new(
      success: false,
      summary: "proposal review blocked by 1 critical finding(s)",
      disposition: "blocked",
      critical_findings: [{ "severity" => "critical", "summary" => "missing dependency" }],
      review_results: [],
      evidence_path: "/tmp/proposal-review.json"
    )
    review_service = instance_double(A3::Application::RunDecompositionProposalReview, call: review_result)
    allow(described_class).to receive(:with_runtime_session).and_yield(session)
    allow(described_class).to receive(:resolve_direct_task).and_return(task)
    allow(A3::Application::RunDecompositionProposalReview).to receive(:new).and_return(review_service)
    expect(A3::Application::RunDecompositionChildCreation).not_to receive(:new)

    described_class.start(["run-decomposition-proposal-review", "A3-v2#5300", "/tmp/project.yaml"], out: out)

    expect(out.string).to include("decomposition draft child creation A3-v2#5300 skipped=proposal_review_not_eligible")
  end

  it "allows child-writer-only Kanban options without repo label mapping" do
    bridge = described_class.send(
      :build_external_task_bridge,
      {
        kanban_command: "kanban",
        kanban_project: "A3-v2",
        kanban_repo_label_map: {},
        kanban_trigger_labels: []
      }
    )

    expect(bridge.task_source).to be_a(A3::Infra::NullExternalTaskSource)
  end

  it "builds a source activity publisher for child-writer-only decomposition options" do
    publisher = described_class.send(
      :build_decomposition_source_activity_publisher,
      {
        kanban_command: "task",
        kanban_command_args: ["kanban:api", "--"],
        kanban_project: "A3-v2",
        kanban_repo_label_map: {},
        kanban_trigger_labels: []
      }
    )

    expect(publisher).to be_a(A3::Infra::KanbanCliTaskActivityPublisher)
  end

  it "imports an external Kanban task before gated child creation uses the parent external id" do
    Dir.mktmpdir do |dir|
      evidence_dir = File.join(dir, "decomposition-evidence", "Portal-240")
      FileUtils.mkdir_p(evidence_dir)
      proposal_evidence = {
        "success" => true,
        "proposal_fingerprint" => "fp-1",
        "proposal" => {
          "children" => [
            {
              "child_key" => "child-1",
              "title" => "Build portal slice",
              "body" => "Implement the portal slice.",
              "acceptance_criteria" => ["works"],
              "labels" => [],
              "depends_on" => [],
              "rationale" => "Needed for the portal."
            }
          ]
        }
      }
      File.write(File.join(evidence_dir, "proposal.json"), JSON.generate(proposal_evidence))
      File.write(
        File.join(evidence_dir, "proposal-review.json"),
        JSON.generate(
          "disposition" => "eligible",
          "request" => {
            "proposal_evidence" => {
              "proposal_fingerprint" => "fp-1"
            }
          }
        )
      )
      external_task = A3::Domain::Task.new(
        ref: "Portal#240",
        kind: :single,
        edit_scope: [:repo_alpha],
        status: :todo,
        external_task_id: 240,
        labels: ["trigger:investigate"]
      )
      A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json")).save(
        A3::Domain::Task.new(
          ref: "Portal#240",
          kind: :single,
          edit_scope: [:repo_alpha],
          status: :todo,
          labels: ["trigger:investigate"]
        )
      )
      source = double("ExternalTaskSource")
      allow(source).to receive(:fetch_by_ref).with("Portal#240").and_return(external_task)
      allow(described_class).to receive(:build_external_task_source).and_return(source)
      allow(described_class).to receive(:build_decomposition_source_activity_publisher).and_return(A3::Infra::NullExternalTaskActivityPublisher.new)
      writer = instance_double(A3::Infra::KanbanCliProposalChildWriter)
      write_result = A3::Infra::KanbanCliProposalChildWriter::Result.new(
        success?: true,
        child_refs: ["Portal#241"],
        child_keys: ["child-1"],
        summary: nil,
        diagnostics: nil
      )
      allow(A3::Infra::KanbanCliProposalChildWriter).to receive(:new).and_return(writer)
      allow(writer).to receive(:call).and_return(write_result)

      out = StringIO.new
      described_class.start(
        [
          "run-decomposition-child-creation",
          "Portal#240",
          "--storage-dir", dir,
          "--gate",
          "--kanban-command", "task",
          "--kanban-project", "Portal",
          "--kanban-repo-label", "repo:portal=repo_alpha"
        ],
        out: out
      )

      expect(writer).to have_received(:call).with(
        parent_task_ref: "Portal#240",
        parent_external_task_id: 240,
        proposal_evidence: proposal_evidence
      )
      expect(out.string).to include("decomposition child creation Portal#240 success=true")
      expect(A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json")).fetch("Portal#240").external_task_id).to eq(240)
    end
  end

  it "runs accept-decomposition-drafts with explicit child selection" do
    out = StringIO.new
    task = A3::Domain::Task.new(ref: "Portal#240", kind: :single, edit_scope: [:repo_alpha], external_task_id: 240)
    repository = instance_double(A3::Infra::JsonTaskRepository, fetch: task)
    allow(described_class).to receive(:build_watch_summary_repositories).and_return(task_repository: repository)
    writer = instance_double(A3::Infra::KanbanCliDraftAcceptanceWriter)
    result = A3::Infra::KanbanCliDraftAcceptanceWriter::Result.new(
      success?: true,
      accepted_refs: ["Portal#241"],
      skipped_refs: [],
      parent_automation_applied: true,
      summary: "accepted 1 draft child ticket(s); skipped 0"
    )
    expect(A3::Infra::KanbanCliDraftAcceptanceWriter).to receive(:new).with(
      command_argv: ["kanban"],
      project: "Portal",
      working_dir: nil
    ).and_return(writer)
    expect(writer).to receive(:call).with(
      parent_task_ref: "Portal#240",
      parent_external_task_id: 240,
      child_refs: ["Portal#241"],
      all: false,
      ready_only: false,
      remove_draft_label: true,
      parent_auto: true
    ).and_return(result)

    described_class.start(
      [
        "accept-decomposition-drafts",
        "Portal#240",
        "--child", "Portal#241",
        "--remove-draft-label",
        "--parent-auto",
        "--kanban-command", "kanban",
        "--kanban-project", "Portal"
      ],
      out: out
    )

    expect(out.string).to include("decomposition draft acceptance Portal#240 success=true")
    expect(out.string).to include("accepted_refs=Portal#241")
    expect(out.string).to include("parent_automation_applied=true")
  end

  it "requires an explicit accept-decomposition-drafts selector" do
    expect do
      described_class.send(
        :parse_accept_decomposition_drafts_options,
        ["Portal#240", "--kanban-command", "kanban", "--kanban-project", "Portal"]
      )
    end.to raise_error(ArgumentError, /exactly one selector/)
  end

  it "raises record not found for direct child creation when no local or external task source can resolve the task" do
    Dir.mktmpdir do |dir|
      expect do
        described_class.start(
          [
            "run-decomposition-child-creation",
            "Portal#999",
            "--storage-dir", dir
          ],
          out: StringIO.new
        )
      end.to raise_error(A3::Domain::RecordNotFound, /Task not found: Portal#999/)
    end
  end

  it "runs decomposition investigation from a stored task, project manifest, and repo sources" do
    Dir.mktmpdir do |dir|
      begin
        repo_source = File.join(dir, "repo-alpha")
        FileUtils.mkdir_p(repo_source)
        File.write(File.join(repo_source, "README.md"), "repo alpha\n")
        commands_dir = File.join(dir, "commands")
        FileUtils.mkdir_p(commands_dir)
        investigate_path = File.join(commands_dir, "investigate.rb")
        File.write(
          investigate_path,
          <<~RUBY
            #!#{RbConfig.ruby}
            require "json"
            request = JSON.parse(File.read(ENV.fetch("A2O_DECOMPOSITION_REQUEST_PATH")))
            raise "missing repo_alpha slot" unless request.fetch("slot_paths").fetch("repo_alpha")
            File.write(
              ENV.fetch("A2O_DECOMPOSITION_RESULT_PATH"),
              JSON.generate(
                "summary" => "investigated \#{request.fetch("title")}",
                "source_description" => request.fetch("description")
              )
            )
          RUBY
        )
        FileUtils.chmod(0o755, investigate_path)
        manifest_path = File.join(dir, "project.yaml")
        File.write(
          manifest_path,
          <<~YAML
            schema_version: 1
            runtime:
              decomposition:
                investigate:
                  command: ["commands/investigate.rb"]
              phases:
                implementation:
                  skill: skills/implementation/base.md
                review:
                  skill: skills/review/default.md
                merge:
                  policy: ff_only
                  target_ref: refs/heads/main
          YAML
        )
        task_repository = A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json"))
        task_repository.save(
          A3::Domain::Task.new(
            ref: "A3-v2#5300",
            kind: :single,
            edit_scope: [:repo_alpha],
            status: :todo,
            labels: ["trigger:investigate"]
          )
        )
        source = instance_double(
          A3::Infra::NullExternalTaskSource,
          fetch_task_packet_by_ref: {
            "ref" => "A3-v2#5300",
            "title" => "Split import workflow",
            "description" => "Create decomposed tasks.",
            "status" => "To do",
            "labels" => ["trigger:investigate"]
          }
        )
        bridge = A3::Infra::KanbanBridgeBundle.new(
          task_source: source,
          task_status_publisher: A3::Infra::NullExternalTaskStatusPublisher.new,
          task_activity_publisher: A3::Infra::NullExternalTaskActivityPublisher.new,
          follow_up_child_writer: nil,
          task_snapshot_reader: A3::Infra::NullExternalTaskSnapshotReader.new
        )
        allow(described_class).to receive(:build_external_task_bridge).and_return(bridge)

        out = StringIO.new
        described_class.start(
          [
            "run-decomposition-investigation",
            "A3-v2#5300",
            manifest_path,
            "--storage-dir", dir,
            "--repo-source", "repo_alpha=#{repo_source}"
          ],
          out: out
        )

        expect(out.string).to include("decomposition investigation A3-v2#5300 success=true")
        evidence = JSON.parse(File.read(File.join(dir, "decomposition-evidence", "A3-v2-5300", "investigation.json")))
        expect(evidence.fetch("request")).to include(
          "title" => "Split import workflow",
          "description" => "Create decomposed tasks."
        )
        expect(evidence.fetch("request").fetch("slot_paths").fetch("repo_alpha")).to start_with(
          File.join(dir, "decomposition-workspaces", "A3-v2-5300")
        )
      ensure
        workspace_root = File.join(dir, "decomposition-workspaces")
        FileUtils.chmod_R("u+w", workspace_root) if File.exist?(workspace_root)
      end
    end
  end

  it "imports an external Kanban task before direct decomposition investigation fetches local storage" do
    Dir.mktmpdir do |dir|
      begin
        repo_source = File.join(dir, "repo-alpha")
        FileUtils.mkdir_p(repo_source)
        File.write(File.join(repo_source, "README.md"), "repo alpha\n")
        commands_dir = File.join(dir, "commands")
        FileUtils.mkdir_p(commands_dir)
        investigate_path = File.join(commands_dir, "investigate.rb")
        File.write(
          investigate_path,
          <<~RUBY
            #!#{RbConfig.ruby}
            require "json"
            request = JSON.parse(File.read(ENV.fetch("A2O_DECOMPOSITION_REQUEST_PATH")))
            File.write(ENV.fetch("A2O_DECOMPOSITION_RESULT_PATH"), JSON.generate("summary" => "investigated \#{request.fetch("title")}"))
          RUBY
        )
        FileUtils.chmod(0o755, investigate_path)
        manifest_path = File.join(dir, "project.yaml")
        File.write(
          manifest_path,
          <<~YAML
            schema_version: 1
            runtime:
              decomposition:
                investigate:
                  command: ["commands/investigate.rb"]
              phases:
                implementation:
                  skill: skills/implementation/base.md
                review:
                  skill: skills/review/default.md
                merge:
                  policy: ff_only
                  target_ref: refs/heads/main
          YAML
        )
        external_task = A3::Domain::Task.new(
          ref: "Portal#240",
          kind: :single,
          edit_scope: [:repo_alpha],
          status: :todo,
          external_task_id: 240,
          labels: ["trigger:investigate"]
        )
        source = double("ExternalTaskSource")
        allow(source).to receive(:fetch_by_ref).with("Portal#240").and_return(external_task)
        allow(source).to receive(:fetch_task_packet_by_external_task_id).with(240).and_return(
          "ref" => "Portal#240",
          "title" => "Split portal work",
          "description" => "Create decomposed portal tasks.",
          "status" => "To do",
          "labels" => ["trigger:investigate"]
        )
        bridge = A3::Infra::KanbanBridgeBundle.new(
          task_source: source,
          task_status_publisher: A3::Infra::NullExternalTaskStatusPublisher.new,
          task_activity_publisher: A3::Infra::NullExternalTaskActivityPublisher.new,
          follow_up_child_writer: nil,
          task_snapshot_reader: A3::Infra::NullExternalTaskSnapshotReader.new
        )
        allow(described_class).to receive(:build_external_task_bridge).and_return(bridge)

        out = StringIO.new
        described_class.start(
          [
            "run-decomposition-investigation",
            "Portal#240",
            manifest_path,
            "--storage-dir", dir,
            "--repo-source", "repo_alpha=#{repo_source}",
            "--kanban-command", "task",
            "--kanban-project", "Portal",
            "--kanban-repo-label", "repo:portal=repo_alpha"
          ],
          out: out
        )

        expect(out.string).to include("decomposition investigation Portal#240 success=true")
        stored_task = A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json")).fetch("Portal#240")
        expect(stored_task.external_task_id).to eq(240)
        evidence = JSON.parse(File.read(File.join(dir, "decomposition-evidence", "Portal-240", "investigation.json")))
        expect(evidence.fetch("request")).to include(
          "title" => "Split portal work",
          "description" => "Create decomposed portal tasks."
        )
      ensure
        workspace_root = File.join(dir, "decomposition-workspaces")
        FileUtils.chmod_R("u+w", workspace_root) if File.exist?(workspace_root)
      end
    end
  end

  it "fails decomposition investigation when source task content is unavailable" do
    Dir.mktmpdir do |dir|
      commands_dir = File.join(dir, "commands")
      FileUtils.mkdir_p(commands_dir)
      investigate_path = File.join(commands_dir, "investigate.rb")
      File.write(investigate_path, "#!#{RbConfig.ruby}\n")
      FileUtils.chmod(0o755, investigate_path)
      manifest_path = File.join(dir, "project.yaml")
      File.write(
        manifest_path,
        <<~YAML
          schema_version: 1
          runtime:
            decomposition:
              investigate:
                command: ["commands/investigate.rb"]
            phases:
              implementation:
                skill: skills/implementation/base.md
              review:
                skill: skills/review/default.md
              merge:
                policy: ff_only
                target_ref: refs/heads/main
        YAML
      )
      task_repository = A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#5300",
          kind: :single,
          edit_scope: [:repo_alpha],
          status: :todo,
          labels: ["trigger:investigate"]
        )
      )

      out = StringIO.new
      expect do
        described_class.start(
          [
            "run-decomposition-investigation",
            "A3-v2#5300",
            manifest_path,
            "--storage-dir", dir
          ],
          out: out
        )
      end.to raise_error(A3::Domain::ConfigurationError, /requires source task title and description/)
    end
  end

  it "uses a shared default storage dir for start-run parsing" do
    allow(Dir).to receive(:pwd).and_return("/tmp/current")

    options = described_class.send(:parse_start_run_options, ["A3-v2#3025", "implementation"])

    expect(options.fetch(:storage_dir)).to eq("/tmp/current/tmp/a3")
  end

  it "uses a shared default storage dir for execute-until-idle parsing" do
    allow(Dir).to receive(:pwd).and_return("/tmp/current")

    options = described_class.send(:parse_execute_until_idle_options, ["/tmp/runtime/project.yaml"])

    expect(options.fetch(:storage_dir)).to eq("/tmp/current/tmp/a3")
  end

  it "keeps explicit storage-dir overrides after centralizing defaults" do
    options = described_class.send(
      :parse_execute_until_idle_options,
      ["--storage-dir", "/tmp/custom-state", "/tmp/runtime/project.yaml"]
    )

    expect(options.fetch(:storage_dir)).to eq("/tmp/custom-state")
  end

  it "rejects conflicting decomposition cleanup modes in the runtime command parser" do
    expect do
      described_class.send(
        :parse_cleanup_decomposition_trial_options,
        ["A2O#254", "--dry-run", "--apply"]
      )
    end.to raise_error(ArgumentError, /only one of --dry-run or --apply/)
  end

  it "accepts the agent decomposition command runner for proposal review parsing" do
    options = described_class.send(
      :parse_run_decomposition_proposal_review_options,
      [
        "A2O#411",
        "/tmp/project.yaml",
        "--decomposition-command-runner", "agent-http",
        "--agent-control-plane-url", "http://127.0.0.1:7393"
      ]
    )

    expect(options.fetch(:decomposition_command_runner)).to eq("agent-http")
    expect(options.fetch(:agent_control_plane_url)).to eq("http://127.0.0.1:7393")
  end

  it "builds a subprocess-cli kanban bridge bundle" do
    Dir.mktmpdir do |dir|
      bundle = described_class.send(
        :build_external_task_bridge,
        {
          kanban_backend: "subprocess-cli",
          kanban_command: "task",
          kanban_command_args: ["kanban:api", "--"],
          kanban_project: "Sample",
          kanban_repo_label_map: { "repo:ui-app" => ["repo_beta"] },
          kanban_trigger_labels: ["trigger:auto-implement"],
          kanban_working_dir: dir
        }
      )

      expect(bundle.task_source).to be_a(A3::Infra::KanbanCliTaskSource)
      expect(bundle.task_status_publisher).to be_a(A3::Infra::KanbanCliTaskStatusPublisher)
      expect(bundle.task_activity_publisher).to be_a(A3::Infra::KanbanCliTaskActivityPublisher)
      expect(bundle.follow_up_child_writer).to be_a(A3::Infra::KanbanCliFollowUpChildWriter)
      expect(bundle.task_snapshot_reader).to be_a(A3::Infra::KanbanCliTaskSnapshotReader)
    end
  end

  it "rejects unsupported kanban backends" do
    expect do
      described_class.send(
        :build_external_task_bridge,
        {
          kanban_backend: "unknown",
          kanban_command: "task",
          kanban_command_args: ["kanban:api", "--"],
          kanban_project: "Sample",
          kanban_repo_label_map: { "repo:ui-app" => ["repo_beta"] },
          kanban_trigger_labels: ["trigger:auto-implement"]
        }
      )
    end.to raise_error(ArgumentError, /Unsupported kanban backend: unknown/)
  end





  it "reports runtime doctor status through the shared runtime session helper" do
    with_env("A3_SECRET" => "token") do
      Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, 'project.yaml')
      preset_dir = File.join(dir, 'presets')
      repo_source_dir = File.join(dir, 'repos', 'repo-alpha')
      FileUtils.mkdir_p(preset_dir)
      FileUtils.mkdir_p(repo_source_dir)
      File.write(manifest_path, "schema_version: 1\nruntime:\n  presets: []\n")
      out = StringIO.new
      descriptor = A3::Domain::RuntimePackageDescriptor.build(
        image_version: 'a3:v2.1.0',
        manifest_path: manifest_path,
        preset_dir: preset_dir,
        storage_backend: :sqlite,
        storage_dir: dir,
        repo_sources: {repo_alpha: repo_source_dir},
        manifest_schema_version: '1',
        required_manifest_schema_version: '1',
        preset_chain: [],
        preset_schema_versions: {},
        required_preset_schema_version: '1',
        secret_reference: 'A3_SECRET'
      )
      session = Struct.new(:options, :runtime_package, :runtime_environment_config, keyword_init: true).new(
        options: {
          manifest_path: manifest_path,
          preset_dir: preset_dir,
          storage_backend: :sqlite,
          storage_dir: dir
        },
        runtime_package: descriptor,
        runtime_environment_config: A3::Bootstrap::RuntimeEnvironmentConfig.runtime_only(runtime_package: descriptor)
      )
      allow(described_class).to receive(:with_runtime_package_session).and_yield(session)

    described_class.start(
      ['doctor-runtime', manifest_path, '--preset-dir', preset_dir, '--storage-backend', 'sqlite', '--storage-dir', dir],
      out: out
    )

      expect(described_class).to have_received(:with_runtime_package_session)
      expect(out.string).to include('runtime_doctor=ok')
      expect(out.string).to include("project_runtime_root=#{File.dirname(manifest_path)}")
      expect(out.string).to include("runtime_summary.mount=state_root=#{dir} logs_root=#{File.join(dir, 'logs')} workspace_root=#{File.join(dir, 'workspaces')} artifact_root=#{File.join(dir, 'artifacts')} migration_marker_path=#{File.join(dir, '.a3', 'scheduler-store-migration.applied')}")
      expect(out.string).to include("runtime_summary.writable_roots=#{dir},#{File.join(dir, 'workspaces')},#{File.join(dir, 'artifacts')}")
      expect(out.string).to include("runtime_summary.repo_sources=#{descriptor.operator_summary.fetch('repo_sources')}")
      expect(out.string).to include("runtime_summary.distribution=#{descriptor.operator_summary.fetch('distribution')}")
      expect(out.string).to include("runtime_summary.persistent_state_model=#{descriptor.operator_summary.fetch('persistent_state_model')}")
      expect(out.string).to include("runtime_summary.retention_policy=#{descriptor.operator_summary.fetch('retention_policy')}")
      expect(out.string).to include("runtime_summary.materialization_model=#{descriptor.operator_summary.fetch('materialization_model')}")
      expect(out.string).to include("runtime_summary.runtime_configuration_model=#{descriptor.operator_summary.fetch('runtime_configuration_model')}")
      expect(out.string).to include("runtime_summary.repository_metadata_model=#{descriptor.operator_summary.fetch('repository_metadata_model')}")
      expect(out.string).to include("runtime_summary.branch_resolution_model=#{descriptor.operator_summary.fetch('branch_resolution_model')}")
      expect(out.string).to include("runtime_summary.credential_boundary_model=#{descriptor.operator_summary.fetch('credential_boundary_model')}")
      expect(out.string).to include("runtime_summary.observability_boundary_model=#{descriptor.operator_summary.fetch('observability_boundary_model')}")
      expect(out.string).to include("runtime_summary.deployment_shape=#{descriptor.operator_summary.fetch('deployment_shape')}")
      expect(out.string).to include("runtime_summary.networking_boundary=#{descriptor.operator_summary.fetch('networking_boundary')}")
      expect(out.string).to include("runtime_summary.upgrade_contract=#{descriptor.operator_summary.fetch('upgrade_contract')}")
      expect(out.string).to include("runtime_summary.fail_fast_policy=#{descriptor.operator_summary.fetch('fail_fast_policy')}")
      expect(out.string).to include("runtime_summary.schema_contract=#{descriptor.operator_summary.fetch('schema_contract')}")
      expect(out.string).to include("runtime_summary.preset_schema_contract=#{descriptor.operator_summary.fetch('preset_schema_contract')}")
      expect(out.string).to include("runtime_summary.repo_source_contract=#{descriptor.operator_summary.fetch('repo_source_contract')}")
      expect(out.string).to include("runtime_summary.secret_contract=#{descriptor.operator_summary.fetch('secret_contract')}")
      expect(out.string).to include("runtime_summary.migration_contract=#{descriptor.operator_summary.fetch('migration_contract')}")
      expect(out.string).to include("runtime_summary.runtime_contract=#{descriptor.operator_summary.fetch('runtime_contract')}")
      expect(out.string).to include("runtime_summary.repo_source_action=#{descriptor.operator_summary.fetch('repo_source_action')}")
      expect(out.string).to include("runtime_summary.preset_schema_action=#{descriptor.operator_summary.fetch('preset_schema_action')}")
      expect(out.string).to include("runtime_summary.secret_delivery_action=#{descriptor.operator_summary.fetch('secret_delivery_action')}")
      expect(out.string).to include("runtime_summary.scheduler_store_migration_action=#{descriptor.operator_summary.fetch('scheduler_store_migration_action')}")
      expect(out.string).to include("runtime_summary.startup_checklist=#{descriptor.operator_summary.fetch('startup_checklist')}")
      expect(out.string).to include("runtime_summary.execution_modes=#{descriptor.operator_summary.fetch('execution_modes')}")
      expect(out.string).to include("runtime_summary.execution_mode_contract=#{descriptor.operator_summary.fetch('execution_mode_contract')}")
      expect(out.string).to include("runtime_summary.startup_readiness=ready")
      expect(out.string).to include("runtime_summary.recommended_execution_mode=one_shot_cli")
      expect(out.string).to include("runtime_summary.recommended_execution_mode_reason=runtime contract satisfied; use one_shot_cli to validate execution or start scheduler processing")
      expect(out.string).to include("runtime_summary.recommended_execution_mode_command=#{descriptor.operator_summary.fetch('runtime_validation_command')}")
      expect(out.string).to include("runtime_summary.doctor_command=#{descriptor.operator_summary.fetch('doctor_command')}")
      expect(out.string).to include("runtime_summary.migration_command=#{descriptor.operator_summary.fetch('migration_command')}")
      expect(out.string).to include("runtime_summary.runtime_command=#{descriptor.operator_summary.fetch('runtime_command')}")
      expect(out.string).to include("runtime_summary.runtime_validation_command=#{descriptor.operator_summary.fetch('runtime_validation_command')}")
      expect(out.string).to include("runtime_summary.next_command=#{descriptor.operator_summary.fetch('runtime_command')}")
      expect(out.string).to include("runtime_summary.startup_sequence=#{descriptor.operator_summary.fetch('startup_sequence')}")
      expect(out.string).to include("runtime_summary.operator_action=#{descriptor.operator_summary.fetch('operator_action')}")
      expect(out.string).to include("runtime_summary.contract_health=project_config_schema=ok preset_schema=ok repo_sources=ok secret_delivery=ok scheduler_store_migration=ok")
      expect(out.string).to include("runtime_summary.operator_guidance=startup ready; runtime package contract satisfied")
      expect(out.string).to include("runtime_summary.startup_blockers=none")
      expect(out.string).to include("distribution_summary.image_ref=#{descriptor.distribution_summary.fetch('image_ref')}")
      expect(out.string).to include("distribution_summary.runtime_entrypoint=#{descriptor.distribution_summary.fetch('runtime_entrypoint')}")
      expect(out.string).to include("distribution_summary.doctor_entrypoint=#{descriptor.distribution_summary.fetch('doctor_entrypoint')}")
      expect(out.string).to include("distribution_summary.migration_entrypoint=#{descriptor.distribution_summary.fetch('migration_entrypoint')}")
      expect(out.string).to include("distribution_summary.project_config_schema_version=#{descriptor.distribution_summary.fetch('project_config_schema_version')}")
      expect(out.string).to include("distribution_summary.required_project_config_schema_version=#{descriptor.distribution_summary.fetch('required_project_config_schema_version')}")
      expect(out.string).to include("distribution_summary.schema_contract=#{descriptor.distribution_summary.fetch('schema_contract')}")
      expect(out.string).to include("distribution_summary.preset_chain=#{descriptor.distribution_summary.fetch('preset_chain').join(',')}")
      expect(out.string).to include("distribution_summary.preset_schema_versions=#{descriptor.distribution_summary.fetch('preset_schema_versions').map { |preset, version| "#{preset}=#{version}" }.join(',')}")
      expect(out.string).to include("distribution_summary.required_preset_schema_version=#{descriptor.distribution_summary.fetch('required_preset_schema_version')}")
      expect(out.string).to include("distribution_summary.preset_schema_contract=#{descriptor.distribution_summary.fetch('preset_schema_contract')}")
      expect(out.string).to include("distribution_summary.secret_delivery_mode=#{descriptor.distribution_summary.fetch('secret_delivery_mode')}")
      expect(out.string).to include("distribution_summary.secret_reference=#{descriptor.distribution_summary.fetch('secret_reference')}")
      expect(out.string).to include("distribution_summary.secret_contract=#{descriptor.distribution_summary.fetch('secret_contract')}")
      expect(out.string).to include("distribution_summary.scheduler_store_migration_state=#{descriptor.distribution_summary.fetch('scheduler_store_migration_state')}")
      expect(out.string).to include("distribution_summary.migration_contract=#{descriptor.distribution_summary.fetch('migration_contract')}")
      expect(out.string).to include("distribution_summary.persistent_state_model=#{descriptor.distribution_summary.fetch('persistent_state_model')}")
      expect(out.string).to include("distribution_summary.retention_policy=#{descriptor.distribution_summary.fetch('retention_policy')}")
      expect(out.string).to include("distribution_summary.materialization_model=#{descriptor.distribution_summary.fetch('materialization_model')}")
      expect(out.string).to include("distribution_summary.runtime_configuration_model=#{descriptor.distribution_summary.fetch('runtime_configuration_model')}")
      expect(out.string).to include("distribution_summary.repository_metadata_model=#{descriptor.distribution_summary.fetch('repository_metadata_model')}")
      expect(out.string).to include("distribution_summary.branch_resolution_model=#{descriptor.distribution_summary.fetch('branch_resolution_model')}")
      expect(out.string).to include("distribution_summary.credential_boundary_model=#{descriptor.distribution_summary.fetch('credential_boundary_model')}")
      expect(out.string).to include("distribution_summary.observability_boundary_model=#{descriptor.distribution_summary.fetch('observability_boundary_model')}")
      expect(out.string).to include("distribution_summary.deployment_shape=#{descriptor.distribution_summary.fetch('deployment_shape')}")
      expect(out.string).to include("distribution_summary.networking_boundary=#{descriptor.distribution_summary.fetch('networking_boundary')}")
      expect(out.string).to include("distribution_summary.upgrade_contract=#{descriptor.distribution_summary.fetch('upgrade_contract')}")
      expect(out.string).to include("distribution_summary.fail_fast_policy=#{descriptor.distribution_summary.fetch('fail_fast_policy')}")
      expect(out.string).to include("writable_roots=#{dir},#{File.join(dir, 'workspaces')},#{File.join(dir, 'artifacts')}")
      expect(out.string).to include("mount_summary.state_root=#{dir}")
      expect(out.string).to include("mount_summary.logs_root=#{File.join(dir, 'logs')}")
      expect(out.string).to include("repo_source_paths=repo_alpha=#{repo_source_dir}")
      expect(out.string).to include('repo_source_details=explicit_map:repo_alpha')
      expect(out.string).to include('check.project_config_path=ok')
      end
    end
  end

  it "prints a runtime package descriptor through the shared runtime session helper" do
    out = StringIO.new
    descriptor = A3::Domain::RuntimePackageDescriptor.build(
      image_version: 'a3:v2.1.0',
      manifest_path: '/tmp/runtime/project.yaml',
      preset_dir: '/tmp/runtime/presets',
      storage_backend: :sqlite,
      storage_dir: '/tmp/runtime/state',
      repo_sources: {repo_alpha: '/tmp/repos/repo-alpha', repo_beta: '/tmp/repos/repo-beta'},
      manifest_schema_version: '1',
      required_manifest_schema_version: '1',
      preset_chain: [],
      preset_schema_versions: {},
      required_preset_schema_version: '1',
        secret_reference: 'A3_SECRET'
    )
    session = Struct.new(:options, :runtime_package, keyword_init: true).new(
      options: {
        manifest_path: '/tmp/runtime/project.yaml',
        preset_dir: '/tmp/runtime/presets',
        storage_backend: :sqlite,
        storage_dir: '/tmp/runtime/state'
      },
      runtime_package: descriptor
    )
    allow(described_class).to receive(:with_runtime_package_session).and_yield(session)

    described_class.start(
      ['show-runtime-package', '/tmp/runtime/project.yaml', '--preset-dir', '/tmp/runtime/presets', '--storage-backend', 'sqlite', '--storage-dir', '/tmp/runtime/state'],
      out: out
    )

    expect(described_class).to have_received(:with_runtime_package_session)
    expect(out.string).to include('image_version=a3:v2.1.0')
    expect(out.string).to include('project_config_path=/tmp/runtime/project.yaml')
    expect(out.string).to include('project_runtime_root=/tmp/runtime')
    expect(out.string).to include('runtime_summary.mount=state_root=/tmp/runtime/state logs_root=/tmp/runtime/state/logs workspace_root=/tmp/runtime/state/workspaces artifact_root=/tmp/runtime/state/artifacts migration_marker_path=/tmp/runtime/state/.a3/scheduler-store-migration.applied')
    expect(out.string).to include('runtime_summary.writable_roots=/tmp/runtime/state,/tmp/runtime/state/workspaces,/tmp/runtime/state/artifacts')
    expect(out.string).to include('runtime_summary.repo_sources=strategy=explicit_map slots=repo_alpha,repo_beta paths=repo_alpha=/tmp/repos/repo-alpha,repo_beta=/tmp/repos/repo-beta')
    expect(out.string).to include('runtime_summary.distribution=image_ref=a3-engine:a3:v2.1.0 runtime_entrypoint=bin/a3 doctor_entrypoint=bin/a3 doctor-runtime')
    expect(out.string).to include('runtime_summary.persistent_state_model=scheduler_state_root=/tmp/runtime/state/scheduler task_repository_root=/tmp/runtime/state/tasks run_repository_root=/tmp/runtime/state/runs evidence_root=/tmp/runtime/state/evidence blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses artifact_owner_cache_root=/tmp/runtime/state/artifact_owner_cache logs_root=/tmp/runtime/state/logs workspace_root=/tmp/runtime/state/workspaces artifact_root=/tmp/runtime/state/artifacts')
    expect(out.string).to include('runtime_summary.retention_policy=terminal_workspace_cleanup=retention_policy_controlled blocked_evidence_retention=independent_from_scheduler_cleanup image_upgrade_cleanup_trigger=none')
    expect(out.string).to include('runtime_summary.materialization_model=repo_slot_namespace=task_workspace_fixed implementation_workspace=ticket_workspace review_workspace=runtime_workspace verification_workspace=runtime_workspace merge_workspace=runtime_workspace runtime_workspace_kind=logical_phase_workspace physical_workspace_layout=worker_gateway_mode_defined agent_materialized_runtime_workspace=per_run_materialized missing_repo_rescue=forbidden source_descriptor_alignment=required_before_phase_start')
    expect(out.string).to include('runtime_summary.runtime_configuration_model=project_config_path=required preset_dir=required storage_backend=required state_root=required workspace_root=required artifact_root=required repo_source_strategy=required repository_metadata=required authoritative_branch_resolution=required integration_target_resolution=required secret_reference=required')
    expect(out.string).to include('runtime_summary.deployment_shape=runtime_package=single_project writable_state=isolated scheduler_instance=single_project state_boundary=project secret_boundary=project')
    expect(out.string).to include('runtime_summary.networking_boundary=outbound=git,issue_api,package_registry,llm_gateway,verification_service secret_source=secret_store token_scope=project')
    expect(out.string).to include('runtime_summary.upgrade_contract=image_upgrade=independent project_config_schema_version=1 preset_schema_version=1 state_migration=explicit')
    expect(out.string).to include('runtime_summary.fail_fast_policy=project_config_schema_mismatch=fail_fast preset_schema_conflict=fail_fast writable_mount_missing=fail_fast secret_missing=fail_fast scheduler_store_migration_pending=fail_fast')
    expect(out.string).to include('runtime_summary.repo_source_contract=repo_source_strategy=explicit_map repo_source_slots=repo_alpha,repo_beta')
    expect(out.string).to include('runtime_summary.secret_contract=secret_delivery_mode=environment_variable secret_reference=A3_SECRET')
    expect(out.string).to include('runtime_summary.migration_contract=scheduler_store_migration_state=not_required')
    expect(out.string).to include('runtime_summary.schema_contract=project_config_schema_version=1 required_project_config_schema_version=1')
    expect(out.string).to include('runtime_summary.preset_schema_contract=required_preset_schema_version=1 preset_schema_versions=')
    expect(out.string).to include('runtime_summary.runtime_contract=project_config_schema_version=1 required_project_config_schema_version=1 required_preset_schema_version=1 preset_schema_versions= repo_source_strategy=explicit_map repo_source_slots=repo_alpha,repo_beta secret_delivery_mode=environment_variable secret_reference=A3_SECRET scheduler_store_migration_state=not_required')
    expect(out.string).to include('runtime_summary.credential_boundary_model=secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only')
    expect(out.string).to include('runtime_summary.observability_boundary_model=operator_logs_root=/tmp/runtime/state/logs blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses evidence_root=/tmp/runtime/state/evidence validation_output=stdout_only workspace_debug_reference=path_only')
    expect(out.string).to include('runtime_summary.repo_source_action=provide writable repo sources for repo_alpha,repo_beta')
    expect(out.string).to include('runtime_summary.preset_schema_action=no preset schema action required')
    expect(out.string).to include('runtime_summary.secret_delivery_action=provide secrets via environment variable A3_SECRET')
    expect(out.string).to include('runtime_summary.scheduler_store_migration_action=scheduler store migration not required')
    expect(out.string).to include('runtime_summary.startup_checklist=provide writable repo sources for repo_alpha,repo_beta; provide secrets via environment variable A3_SECRET; scheduler store migration not required')
    expect(out.string).to include("runtime_summary.execution_modes=#{descriptor.operator_summary.fetch('execution_modes')}")
    expect(out.string).to include("runtime_summary.execution_mode_contract=#{descriptor.operator_summary.fetch('execution_mode_contract')}")
    expect(out.string).to include('runtime_summary.descriptor_startup_readiness=descriptor_ready')
    expect(out.string).to include('runtime_summary.doctor_command=bin/a3 doctor-runtime /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state')
    expect(out.string).to include('runtime_summary.migration_command=bin/a3 migrate-scheduler-store /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state')
    expect(out.string).to include('runtime_summary.runtime_command=bin/a3 execute-until-idle /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state')
    expect(out.string).to include('runtime_summary.runtime_validation_command=bin/a3 doctor-runtime /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state && bin/a3 execute-until-idle /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state')
    expect(out.string).to include('runtime_summary.startup_sequence=doctor=bin/a3 doctor-runtime /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state migrate=skip runtime=bin/a3 execute-until-idle /tmp/runtime/project.yaml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state')
    expect(out.string).to include('runtime_summary.operator_action=provide writable repo sources for repo_alpha,repo_beta; provide secrets via environment variable A3_SECRET; scheduler store migration not required')
    expect(out.string).to include('distribution_summary.image_ref=a3-engine:a3:v2.1.0')
    expect(out.string).to include('distribution_summary.runtime_entrypoint=bin/a3')
    expect(out.string).to include('distribution_summary.doctor_entrypoint=bin/a3 doctor-runtime')
    expect(out.string).to include('distribution_summary.migration_entrypoint=bin/a3 migrate-scheduler-store')
    expect(out.string).to include('distribution_summary.preset_chain=')
    expect(out.string).to include('distribution_summary.preset_schema_versions=')
    expect(out.string).to include('distribution_summary.required_preset_schema_version=1')
    expect(out.string).to include('distribution_summary.preset_schema_contract=required_preset_schema_version=1 preset_schema_versions=')
    expect(out.string).to include('distribution_summary.secret_delivery_mode=environment_variable')
    expect(out.string).to include('distribution_summary.secret_reference=A3_SECRET')
    expect(out.string).to include('distribution_summary.secret_contract=secret_delivery_mode=environment_variable secret_reference=A3_SECRET')
    expect(out.string).to include('distribution_summary.credential_boundary_model=secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only')
    expect(out.string).to include('distribution_summary.observability_boundary_model=operator_logs_root=/tmp/runtime/state/logs blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses evidence_root=/tmp/runtime/state/evidence validation_output=stdout_only workspace_debug_reference=path_only')
    expect(out.string).to include('distribution_summary.scheduler_store_migration_state=not_required')
    expect(out.string).to include('distribution_summary.migration_contract=scheduler_store_migration_state=not_required')
    expect(out.string).to include('writable_roots=/tmp/runtime/state,/tmp/runtime/state/workspaces,/tmp/runtime/state/artifacts')
    expect(out.string).to include('repo_source_paths=repo_alpha=/tmp/repos/repo-alpha,repo_beta=/tmp/repos/repo-beta')
    expect(out.string).to include('repo_source_strategy=explicit_map')
    expect(out.string).to include('repo_source_slots=repo_alpha,repo_beta')
    expect(out.string).to include('repo_source_details=explicit_map:repo_alpha,repo_beta')
  end

  it "runs scheduler store migration through the shared runtime package session helper" do
    out = StringIO.new
    runtime_package = instance_double(
      A3::Domain::RuntimePackageDescriptor,
      scheduler_store_migration_state: :pending
    )
    session = Struct.new(:options, :runtime_package, keyword_init: true).new(
      options: {
        manifest_path: "/tmp/runtime/project.yaml",
        preset_dir: "/tmp/runtime/presets",
        storage_backend: :sqlite,
        storage_dir: "/tmp/runtime/state"
      },
      runtime_package: runtime_package
    )
    allow(described_class).to receive(:with_runtime_package_session).and_yield(session)
    result = Struct.new(:status, :migration_state, :marker_path, :message).new(
      :applied,
      :applied,
      Pathname("/tmp/runtime/state/.a3/scheduler-store-migration.applied"),
      "scheduler store migration marker written"
    )
    allow(A3::Application::MigrateSchedulerStore).to receive(:new).with(runtime_package: runtime_package).and_return(
      instance_double(A3::Application::MigrateSchedulerStore, call: result)
    )

    described_class.start(
      ["migrate-scheduler-store", "/tmp/runtime/project.yaml", "--preset-dir", "/tmp/runtime/presets", "--storage-backend", "sqlite", "--storage-dir", "/tmp/runtime/state"],
      out: out
    )

    expect(out.string).to include("scheduler_store_migration=applied")
    expect(out.string).to include("migration_state=applied")
    expect(out.string).to include("migration_marker_path=/tmp/runtime/state/.a3/scheduler-store-migration.applied")
    expect(out.string).to include("message=scheduler store migration marker written")
  end

  it "routes manifest project-context commands through the shared manifest session helper" do
    out = StringIO.new
    project_surface = instance_double(A3::Domain::ProjectSurface, resolve: "skills/implementation/base.md")
    merge_config = Struct.new(:target, :policy).new(:merge_to_parent, :ff_only)
    session = Struct.new(:options, :project_surface, :project_context, :container, keyword_init: true).new(
      options: {
        task_kind: :child,
        repo_scope: :repo_alpha,
        phase: :review
      },
      project_surface: project_surface,
      project_context: instance_double(A3::Domain::ProjectContext, merge_config: merge_config, surface: project_surface),
      container: {}
    )
    allow(described_class).to receive(:with_manifest_session).and_yield(session)

    described_class.start(
      ["show-project-context", "/tmp/project.yaml", "--preset-dir", "/tmp/presets", "--task-kind", "child", "--repo-scope", "repo_alpha", "--phase", "review"],
      out: out
    )

    expect(described_class).to have_received(:with_manifest_session)
    expect(out.string).to include("merge_target=merge_to_parent")
    expect(out.string).to include("implementation_skill=skills/implementation/base.md")
  end

  it "builds manifest sessions through the public bootstrap manifest session API" do
    out = StringIO.new
    project_surface = instance_double(A3::Domain::ProjectSurface, resolve: "skills/implementation/base.md")
    merge_config = Struct.new(:target, :policy).new(:merge_to_parent, :ff_only)
    bootstrap_session = Struct.new(:project_surface, :project_context).new(
      project_surface,
      instance_double(A3::Domain::ProjectContext, merge_config: merge_config, surface: project_surface)
    )
    allow(A3::Bootstrap).to receive(:manifest_session).and_return(bootstrap_session)

    described_class.start(
      ["show-project-context", "/tmp/project.yaml", "--preset-dir", "/tmp/presets", "--task-kind", "child", "--repo-scope", "repo_alpha", "--phase", "review"],
      out: out
    )

    expect(A3::Bootstrap).to have_received(:manifest_session).with(
      manifest_path: "/tmp/project.yaml",
      preset_dir: "/tmp/presets"
    )
    expect(out.string).to include("merge_target=merge_to_parent")
  end

  it "starts a run and persists it through JSON repositories" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      task_repository = A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json"))
      run_repository = A3::Infra::JsonRunRepository.new(File.join(dir, "runs.json"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha, :repo_beta],
          parent_ref: "A3-v2#3022"
        )
      )

      out = StringIO.new

      described_class.start(
        [
          "start-run",
          "A3-v2#3025",
          "implementation",
          "--storage-dir", dir,
          *repo_source_args(repo_sources),
          "--source-type", "branch_head",
          "--source-ref", "refs/heads/a2o/work/A3-v2-3025",
          "--bootstrap-marker", "workspace-hook:v1",
          "--review-base", "base123",
          "--review-head", "head456"
        ],
        out: out,
        run_id_generator: -> { "run-1" }
      )

      persisted_task = task_repository.fetch("A3-v2#3025")
      persisted_run = run_repository.fetch("run-1")

      expect(out.string).to include("started run run-1")
      expect(persisted_task.current_run_ref).to eq("run-1")
      expect(persisted_task.status).to eq(:in_progress)
      expect(persisted_run.phase).to eq(:implementation)
      expect(persisted_run.artifact_owner.snapshot_version).to eq("head456")
    end
  end

  it "completes a run and updates task lifecycle through JSON repositories" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json"))
      run_repository = A3::Infra::JsonRunRepository.new(File.join(dir, "runs.json"))

      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha, :repo_beta],
          status: :in_progress,
          current_run_ref: "run-1",
          parent_ref: "A3-v2#3022"
        )
      )
      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-1",
          task_ref: "A3-v2#3025",
          phase: :implementation,
          workspace_kind: :ticket_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :ticket_workspace,
            source_type: :branch_head,
            ref: "refs/heads/a2o/work/A3-v2-3025",
            task_ref: "A3-v2#3025"
          ),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(
            edit_scope: [:repo_alpha],
            verification_scope: [:repo_alpha, :repo_beta],
            ownership_scope: :task
          ),
          review_target: A3::Domain::ReviewTarget.new(
            base_commit: "base123",
            head_commit: "head456",
            task_ref: "A3-v2#3025",
            phase_ref: :review
          ),
          artifact_owner: A3::Domain::ArtifactOwner.new(
            owner_ref: "A3-v2#3022",
            owner_scope: :task,
            snapshot_version: "head456"
          )
        )
      )

      out = StringIO.new

      described_class.start(
        [
          "complete-run",
          "A3-v2#3025",
          "run-1",
          "completed",
          "--storage-dir", dir
        ],
        out: out,
        run_id_generator: -> { "unused" }
      )

      persisted_task = task_repository.fetch("A3-v2#3025")
      persisted_run = run_repository.fetch("run-1")

      expect(out.string).to include("completed run run-1")
      expect(persisted_task.status).to eq(:verifying)
      expect(persisted_task.current_run_ref).to be_nil
      expect(persisted_run.terminal_outcome).to eq(:completed)
    end
  end

  it "starts a run through sqlite repositories when sqlite backend is selected" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      run_repository = A3::Infra::SqliteRunRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha, :repo_beta],
          parent_ref: "A3-v2#3022"
        )
      )

      out = StringIO.new

      described_class.start(
        [
          "start-run",
          "A3-v2#3025",
          "implementation",
          "--storage-backend", "sqlite",
          "--storage-dir", dir,
          *repo_source_args(repo_sources),
          "--source-type", "branch_head",
          "--source-ref", "refs/heads/a2o/work/A3-v2-3025",
          "--bootstrap-marker", "workspace-hook:v1",
          "--review-base", "base123",
          "--review-head", "head456"
        ],
        out: out,
        run_id_generator: -> { "run-sqlite-1" }
      )

      persisted_task = task_repository.fetch("A3-v2#3025")
      persisted_run = run_repository.fetch("run-sqlite-1")

      expect(out.string).to include("started run run-sqlite-1")
      expect(persisted_task.current_run_ref).to eq("run-sqlite-1")
      expect(persisted_run.phase).to eq(:implementation)
    end
  end

  it "fails fast when start-run omits bootstrap marker" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      task_repository = A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha]
        )
      )

      expect do
        described_class.start(
          [
            "start-run",
            "A3-v2#3025",
            "implementation",
            "--storage-dir", dir,
            *repo_source_args(repo_sources),
            "--source-type", "branch_head",
            "--source-ref", "refs/heads/a2o/work/A3-v2-3025",
            "--review-base", "base123",
            "--review-head", "head456"
          ],
          out: StringIO.new,
          run_id_generator: -> { "run-missing-marker" }
        )
      end.to raise_error(KeyError)
    end
  end

  it "prints rerun planning through sqlite repositories" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      run_repository = A3::Infra::SqliteRunRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha, :repo_beta],
          parent_ref: "A3-v2#3022"
        )
      )
      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-rerun-1",
          task_ref: "A3-v2#3025",
          phase: :review,
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :runtime_workspace,
            source_type: :detached_commit,
            ref: "head456",
            task_ref: "A3-v2#3025"
          ),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(
            edit_scope: [:repo_alpha],
            verification_scope: [:repo_alpha, :repo_beta],
            ownership_scope: :task
          ),
          review_target: A3::Domain::ReviewTarget.new(
            base_commit: "base123",
            head_commit: "head456",
            task_ref: "A3-v2#3025",
            phase_ref: :review
          ),
          artifact_owner: A3::Domain::ArtifactOwner.new(
            owner_ref: "A3-v2#3022",
            owner_scope: :task,
            snapshot_version: "head456"
          )
        )
      )

      out = StringIO.new

      described_class.start(
        [
          "plan-rerun",
          "A3-v2#3025",
          "run-rerun-1",
          "--storage-backend", "sqlite",
          "--storage-dir", dir,
          "--source-type", "detached_commit",
          "--source-ref", "head456",
          "--review-base", "base123",
          "--review-head", "head456",
          "--snapshot-version", "head456"
        ],
        out: out,
        run_id_generator: -> { "unused" }
      )

      expect(out.string).to include("rerun decision same_phase_retry")
      expect(out.string).to include("operator_action_required=false")
    end
  end

  it "prints actionable persisted rerun recovery through sqlite repositories" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "project.yaml")
      preset_dir = File.join(dir, "presets")
      FileUtils.mkdir_p(preset_dir)
      File.write(manifest_path, "schema_version: 1\nruntime:\n  presets: []\n")
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      run_repository = A3::Infra::SqliteRunRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha, :repo_beta],
          parent_ref: "A3-v2#3022"
        )
      )
      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-recovery-1",
          task_ref: "A3-v2#3025",
          phase: :review,
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :runtime_workspace,
            source_type: :detached_commit,
            ref: "head456",
            task_ref: "A3-v2#3025"
          ),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(
            edit_scope: [:repo_alpha],
            verification_scope: [:repo_alpha, :repo_beta],
            ownership_scope: :task
          ),
          review_target: A3::Domain::ReviewTarget.new(
            base_commit: "base123",
            head_commit: "head456",
            task_ref: "A3-v2#3025",
            phase_ref: :review
          ),
          artifact_owner: A3::Domain::ArtifactOwner.new(
            owner_ref: "A3-v2#3022",
            owner_scope: :task,
            snapshot_version: "head456"
          )
        )
      )

      out = StringIO.new
      described_class.start(
        [
          "recover-rerun",
          "A3-v2#3025",
          "run-recovery-1",
          "--storage-backend", "sqlite",
          "--storage-dir", dir,
          "--preset-dir", preset_dir,
          "--source-type", "detached_commit",
          "--source-ref", "head456",
          "--review-base", "base123",
          "--review-head", "head456",
          "--snapshot-version", "head456",
          manifest_path
        ],
        out: out,
        run_id_generator: -> { "unused" }
      )

      expect(out.string).to include("rerun recovery same_phase_retry")
      expect(out.string).to include("action=retry_current_phase")
      expect(out.string).to include("target_phase=review")
      expect(out.string).to include("runtime_package_next_command=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
      expect(out.string).to include("runtime_package_guidance=startup blocked by secret_delivery; provide secrets via environment variable A3_SECRET; run bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
      expect(out.string).to include("runtime_package_contract_health=project_config_schema=ok preset_schema=ok repo_sources=ok secret_delivery=missing scheduler_store_migration=ok")
      expect(out.string).to include("runtime_package_execution_modes=one_shot_cli=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir} | bin/a3 migrate-scheduler-store #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir} | bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir} ; scheduler_loop=bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir} ; doctor_inspect=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
      expect(out.string).to include("runtime_package_execution_mode_contract=one_shot_cli=operator_driven_doctor_migration_runtime ; scheduler_loop=continuous_runnable_processing_after_runtime_ready ; doctor_inspect=configuration_and_mount_validation_only")
      expect(out.string).to include("runtime_package_schema_action=update project.yaml schema to 1")
      expect(out.string).to include("runtime_package_preset_schema_action=no preset schema action required")
      expect(out.string).to include("runtime_package_repo_source_action=no repo source action required")
      expect(out.string).to include("runtime_package_secret_delivery_action=provide secrets via environment variable A3_SECRET")
      expect(out.string).to include("runtime_package_scheduler_store_migration_action=scheduler store migration not required")
      expect(out.string).to include("runtime_package_recommended_execution_mode=doctor_inspect")
      expect(out.string).to include("runtime_package_recommended_execution_mode_reason=runtime is not ready; use doctor_inspect until blockers are resolved")
      expect(out.string).to include("runtime_package_recommended_execution_mode_command=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
      expect(out.string).to include("runtime_package_migration_command=bin/a3 migrate-scheduler-store #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
      expect(out.string).to include("runtime_package_doctor_command=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
      expect(out.string).to include("runtime_package_runtime_command=bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
      expect(out.string).to include("runtime_package_runtime_validation_command=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
      expect(out.string).to include("runtime_package_startup_sequence=doctor=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir} migrate=blocked runtime=blocked")
      expect(out.string).to include("runtime_package_startup_blockers=secret_delivery")
      expect(out.string).to include("runtime_package_persistent_state_model=scheduler_state_root=#{File.join(dir, 'scheduler')} task_repository_root=#{File.join(dir, 'tasks')} run_repository_root=#{File.join(dir, 'runs')} evidence_root=#{File.join(dir, 'evidence')} blocked_diagnosis_root=#{File.join(dir, 'blocked_diagnoses')} artifact_owner_cache_root=#{File.join(dir, 'artifact_owner_cache')} logs_root=#{File.join(dir, 'logs')} workspace_root=#{File.join(dir, 'workspaces')} artifact_root=#{File.join(dir, 'artifacts')}")
      expect(out.string).to include("runtime_package_retention_policy=terminal_workspace_cleanup=retention_policy_controlled blocked_evidence_retention=independent_from_scheduler_cleanup image_upgrade_cleanup_trigger=none")
      expect(out.string).to include("runtime_package_materialization_model=repo_slot_namespace=task_workspace_fixed implementation_workspace=ticket_workspace review_workspace=runtime_workspace verification_workspace=runtime_workspace merge_workspace=runtime_workspace runtime_workspace_kind=logical_phase_workspace physical_workspace_layout=worker_gateway_mode_defined agent_materialized_runtime_workspace=per_run_materialized missing_repo_rescue=forbidden source_descriptor_alignment=required_before_phase_start")
      expect(out.string).to include("runtime_package_runtime_configuration_model=project_config_path=required preset_dir=required storage_backend=required state_root=required workspace_root=required artifact_root=required repo_source_strategy=required repository_metadata=required authoritative_branch_resolution=required integration_target_resolution=required secret_reference=required")
      expect(out.string).to include("runtime_package_observability_boundary_model=operator_logs_root=#{File.join(dir, 'logs')} blocked_diagnosis_root=#{File.join(dir, 'blocked_diagnoses')} evidence_root=#{File.join(dir, 'evidence')} validation_output=stdout_only workspace_debug_reference=path_only")
      expect(out.string).to include("runtime_package_deployment_shape=runtime_package=single_project writable_state=isolated scheduler_instance=single_project state_boundary=project secret_boundary=project")
      expect(out.string).to include("runtime_package_networking_boundary=outbound=git,issue_api,package_registry,llm_gateway,verification_service secret_source=secret_store token_scope=project")
      expect(out.string).to include("runtime_package_upgrade_contract=image_upgrade=independent project_config_schema_version=1 preset_schema_version=1 state_migration=explicit")
      expect(out.string).to include("runtime_package_fail_fast_policy=project_config_schema_mismatch=fail_fast preset_schema_conflict=fail_fast writable_mount_missing=fail_fast secret_missing=fail_fast scheduler_store_migration_pending=fail_fast")
    end
  end

  it "prints blocked diagnosis through sqlite repositories" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      run_repository = A3::Infra::SqliteRunRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha, :repo_beta],
          status: :blocked,
          parent_ref: "A3-v2#3022"
        )
      )
      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-blocked-1",
          task_ref: "A3-v2#3025",
          phase: :review,
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :runtime_workspace,
            source_type: :detached_commit,
            ref: "head456",
            task_ref: "A3-v2#3025"
          ),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(
            edit_scope: [:repo_alpha],
            verification_scope: [:repo_alpha, :repo_beta],
            ownership_scope: :task
          ),
          review_target: A3::Domain::ReviewTarget.new(
            base_commit: "base123",
            head_commit: "head456",
            task_ref: "A3-v2#3025",
            phase_ref: :review
          ),
          artifact_owner: A3::Domain::ArtifactOwner.new(
            owner_ref: "A3-v2#3022",
            owner_scope: :task,
            snapshot_version: "head456"
          ),
          terminal_outcome: :blocked
        )
      )

      out = StringIO.new

      described_class.start(
        [
          "diagnose-blocked",
          "A3-v2#3025",
          "run-blocked-1",
          "--storage-backend", "sqlite",
          "--storage-dir", dir,
          "--expected-state", "runtime workspace available",
          "--observed-state", "repo-beta missing",
          "--failing-command", "codex exec --json -",
          "--diagnostic-summary", "review launch could not resolve runtime workspace",
          "--infra-diagnostic", "missing_path=/tmp/repo-beta",
          "--infra-diagnostic", "exception=Errno::ENOENT"
        ],
        out: out,
        run_id_generator: -> { "unused" }
      )

      expect(out.string).to include("blocked diagnosis blocked")
      expect(out.string).to include("repo-beta missing")
      persisted = run_repository.fetch("run-blocked-1").phase_records.last.blocked_diagnosis
      expect(persisted.infra_diagnostics).to eq(
        "missing_path" => "/tmp/repo-beta",
        "exception" => "Errno::ENOENT"
      )
    end
  end

  it "prints persisted blocked diagnosis and evidence summary through sqlite repositories" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "project.yaml")
      preset_dir = File.join(dir, "presets")
      FileUtils.mkdir_p(preset_dir)
      File.write(manifest_path, "schema_version: 1\nruntime:\n  presets: []\n")
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      run_repository = A3::Infra::SqliteRunRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha, :repo_beta],
          status: :blocked,
          parent_ref: "A3-v2#3022"
        )
      )

      run = A3::Domain::Run.new(
        ref: "run-blocked-2",
        task_ref: "A3-v2#3025",
        phase: :review,
        workspace_kind: :runtime_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :detached_commit,
          ref: "head456",
          task_ref: "A3-v2#3025"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha, :repo_beta],
          ownership_scope: :task
        ),
        review_target: A3::Domain::ReviewTarget.new(
          base_commit: "base123",
          head_commit: "head456",
          task_ref: "A3-v2#3025",
          phase_ref: :review
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "A3-v2#3022",
          owner_scope: :task,
          snapshot_version: "head456"
        ),
        terminal_outcome: :blocked
      ).append_blocked_diagnosis(
        A3::Domain::BlockedDiagnosis.new(
          task_ref: "A3-v2#3025",
          run_ref: "run-blocked-2",
          phase: :review,
          outcome: :blocked,
          review_target: A3::Domain::ReviewTarget.new(
            base_commit: "base123",
            head_commit: "head456",
            task_ref: "A3-v2#3025",
            phase_ref: :review
          ),
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :runtime_workspace,
            source_type: :detached_commit,
            ref: "head456",
            task_ref: "A3-v2#3025"
          ),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(
            edit_scope: [:repo_alpha],
            verification_scope: [:repo_alpha, :repo_beta],
            ownership_scope: :task
          ),
          artifact_owner: A3::Domain::ArtifactOwner.new(
            owner_ref: "A3-v2#3022",
            owner_scope: :task,
            snapshot_version: "head456"
          ),
          expected_state: "runtime workspace available",
          observed_state: "repo-beta missing",
          failing_command: "codex exec --json -",
          diagnostic_summary: "review launch could not resolve runtime workspace",
          infra_diagnostics: { "missing_path" => "/tmp/repo-beta" }
        ),
        execution_record: A3::Domain::PhaseExecutionRecord.new(
          summary: "review launch could not resolve runtime workspace",
          failing_command: "codex exec --json -",
          observed_state: "repo-beta missing",
          diagnostics: {
            "missing_path" => "/tmp/repo-beta",
            "worker_response_bundle" => {
              "success" => false,
              "summary" => "review blocked",
              "failing_command" => "codex exec --json -",
              "observed_state" => "repo-beta missing"
            }
          },
          runtime_snapshot: A3::Domain::PhaseRuntimeSnapshot.new(
            task_kind: :child,
            repo_scope: :repo_alpha,
            phase: :review,
            implementation_skill: "sample-implementation",
            review_skill: "sample-review",
            verification_commands: ["commands/check-style", "commands/verify-all"],
            remediation_commands: ["commands/apply-remediation"],
            workspace_hook: "sample-bootstrap",
            merge_target: :merge_to_parent,
            merge_policy: :ff_only
          )
        )
      )
      run_repository.save(run)

      out = StringIO.new

      described_class.start(
        [
          "show-blocked-diagnosis",
          "A3-v2#3025",
          "run-blocked-2",
          "--storage-backend", "sqlite",
          "--storage-dir", dir,
          "--preset-dir", preset_dir,
          manifest_path
        ],
        out: out,
        run_id_generator: -> { "unused" }
      )

      expect(out.string).to include("blocked diagnosis blocked for run-blocked-2 on A3-v2#3025")
      expect(out.string).to include("phase=review observed=repo-beta missing")
      expect(out.string).to include("recovery decision=requires_operator_action next_action=diagnose_blocked operator_action_required=true")
      expect(out.string).to include("rerun_hint=diagnose blocked state and choose a fresh rerun source")
      expect(out.string).to include("review_target=base123..head456")
      expect(out.string).to include("edit_scope=repo_alpha")
      expect(out.string).to include("verification_scope=repo_alpha,repo_beta")
      expect(out.string).to include("diagnostic.missing_path=/tmp/repo-beta")
    end
  end

  it "reconciles manual merge recovery through json repositories" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json"))
      run_repository = A3::Infra::JsonRunRepository.new(File.join(dir, "runs.json"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "Sample#245",
          kind: :single,
          edit_scope: [:repo_alpha],
          status: :blocked,
          external_task_id: 245
        )
      )
      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-merge-245",
          task_ref: "Sample#245",
          phase: :merge,
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.runtime_integration_record(task_ref: "Sample#245", ref: "refs/heads/a2o/work/Sample-245"),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: %i[repo_alpha], verification_scope: %i[repo_alpha], ownership_scope: :task),
          artifact_owner: A3::Domain::ArtifactOwner.new(owner_ref: "Sample#245", owner_scope: :task, snapshot_version: "merge-head")
        ).append_phase_evidence(
          phase: :merge,
          source_descriptor: A3::Domain::SourceDescriptor.runtime_integration_record(task_ref: "Sample#245", ref: "refs/heads/a2o/work/Sample-245"),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: %i[repo_alpha], verification_scope: %i[repo_alpha], ownership_scope: :task),
          execution_record: A3::Domain::PhaseExecutionRecord.new(
            summary: "merge conflict requires recovery",
            observed_state: "merge_recovery_candidate",
            diagnostics: {
              "merge_recovery" => {
                "status" => "failed",
                "target_ref" => "refs/heads/main",
                "source_ref" => "refs/heads/a2o/work/Sample-245"
              }
            }
          )
        ).complete(outcome: :blocked)
      )

      out = StringIO.new
      described_class.start(
        [
          "reconcile-merge-recovery",
          "Sample#245",
          "run-merge-245",
          "--storage-dir", dir,
          "--target-ref", "refs/heads/main",
          "--source-ref", "refs/heads/a2o/work/Sample-245",
          "--publish-before-head", "before123",
          "--publish-after-head", "after456"
        ],
        out: out,
        run_id_generator: -> { "unused" }
      )

      persisted_task = task_repository.fetch("Sample#245")
      persisted_run = run_repository.fetch("run-merge-245")

      expect(out.string).to include("merge recovery reconciled for run-merge-245 on Sample#245")
      expect(out.string).to include("verification_source_ref=refs/heads/main")
      expect(persisted_task.status).to eq(:verifying)
      expect(persisted_task.verification_source_ref).to eq("refs/heads/main")
      expect(persisted_run.terminal_outcome).to eq(:verification_required)
      expect(persisted_run.phase_records.last.execution_record.diagnostics.fetch("merge_recovery")).to include(
        "status" => "manual_reconciled",
        "target_ref" => "refs/heads/main",
        "source_ref" => "refs/heads/a2o/work/Sample-245",
        "publish_before_head" => "before123",
        "publish_after_head" => "after456"
      )
    end
  end

end
