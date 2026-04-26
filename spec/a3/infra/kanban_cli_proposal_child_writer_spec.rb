# frozen_string_literal: true

RSpec.describe A3::Infra::KanbanCliProposalChildWriter do
  class FakeProposalClient
    attr_reader :created, :labels, :relations
    attr_accessor :fail_after_first_create

    def initialize(existing: [])
      @existing = existing
      @created = []
      @labels = []
      @relations = []
      @comments = []
      @fail_after_first_create = false
    end

    def run_json_command(*args)
      case args.first
      when "task-find"
        @existing
      when "task-create"
        task = { "id" => 5301 + @created.size, "ref" => "A3-v2##{5301 + @created.size}", "title" => args[args.index("--title") + 1], "description" => "created" }
        @created << task
        task
      when "task-relation-list"
        { "subtask" => [] }
      else
        {}
      end
    end

    def run_json_command_with_text_file_option(*args, option_name:, text:, **)
      run_json_command(*args).tap { |task| task["description"] = text if task.is_a?(Hash) }
    end

    def run_command(*args)
      raise A3::Domain::ConfigurationError, "simulated label failure" if @fail_after_first_create && args.first == "task-label-add"

      @labels << args if args.first == "task-label-add"
      @relations << args if args.first == "task-relation-create"
      @comments << args if args.first == "task-comment-create"
      nil
    end

    def run_command_with_text_file_option(*args, **)
      run_command(*args)
    end

    def fetch_task_by_ref(ref)
      (@created + @existing).find { |task| task.fetch("ref") == ref } || raise("missing #{ref}")
    end
  end

  def proposal_evidence(fingerprint: "fp-1", title: "Add routing")
    {
      "proposal_fingerprint" => fingerprint,
      "proposal" => {
        "children" => [
          {
            "child_key" => "child-key-1",
            "title" => title,
            "body" => "Route work.",
            "acceptance_criteria" => ["tested"],
            "labels" => ["repo:alpha"],
            "priority" => 3,
            "depends_on" => [],
            "rationale" => "small boundary"
          }
        ]
      }
    }
  end

  it "creates a child with idempotency key, labels, trigger, and parent relation" do
    client = FakeProposalClient.new
    writer = described_class.new(project: "A3-v2", client: client)

    result = writer.call(parent_task_ref: "A3-v2#5300", parent_external_task_id: 5300, proposal_evidence: proposal_evidence)

    expect(result.success?).to be(true)
    expect(result.child_refs).to eq(["A3-v2#5301"])
    expect(result.child_keys).to eq(["child-key-1"])
    expect(client.created.first.fetch("description")).to include("Child key: child-key-1")
    expect(client.created.first.fetch("description")).to include("Proposal fingerprint: fp-1")
    expect(client.labels.any? { |args| args.include?("trigger:auto-implement") }).to be(true)
    expect(client.labels.any? { |args| args.include?("repo:alpha") }).to be(true)
    expect(client.relations.size).to eq(1)
  end

  it "reuses an existing child by child key even when proposal fingerprint changes" do
    existing = [{ "id" => 5301, "ref" => "A3-v2#5301", "description" => "Child key: child-key-1\nProposal fingerprint: old" }]
    client = FakeProposalClient.new(existing: existing)
    writer = described_class.new(project: "A3-v2", client: client)

    result = writer.call(parent_task_ref: "A3-v2#5300", parent_external_task_id: 5300, proposal_evidence: proposal_evidence(fingerprint: "new"))

    expect(result.success?).to be(true)
    expect(result.child_refs).to eq(["A3-v2#5301"])
    expect(client.created).to eq([])
    expect(client.labels.any? { |args| args.include?("trigger:auto-implement") }).to be(true)
  end

  it "creates blocker relations for child dependencies" do
    client = FakeProposalClient.new
    writer = described_class.new(project: "A3-v2", client: client)
    payload = proposal_evidence
    payload["proposal"]["children"] << payload["proposal"]["children"].first.merge(
      "child_key" => "child-key-2",
      "title" => "Add review",
      "depends_on" => ["child-key-1"]
    )

    result = writer.call(parent_task_ref: "A3-v2#5300", parent_external_task_id: 5300, proposal_evidence: payload)

    expect(result.success?).to be(true)
    expect(client.relations.any? { |args| args.include?("blocked_by") }).to be(true)
  end

  it "returns already-created refs when a later reconciliation write fails" do
    client = FakeProposalClient.new
    client.fail_after_first_create = true
    writer = described_class.new(project: "A3-v2", client: client)

    result = writer.call(parent_task_ref: "A3-v2#5300", parent_external_task_id: 5300, proposal_evidence: proposal_evidence)

    expect(result.success?).to be(false)
    expect(result.child_refs).to eq(["A3-v2#5301"])
    expect(result.child_keys).to eq(["child-key-1"])
    expect(result.diagnostics.fetch("failed_write")).to include("child_key" => "child-key-1")
  end
end
