# frozen_string_literal: true

RSpec.describe A3::Infra::KanbanCliProposalChildWriter do
  class FakeProposalClient
    attr_reader :created, :labels, :relations, :comments, :commands
    attr_accessor :fail_after_first_create, :fail_dependency_relation, :task_find_returns_summaries

    def initialize(existing: [])
      @existing = existing
      @created = []
      @labels = []
      @relations = []
      @comments = []
      @comment_texts = Hash.new { |hash, key| hash[key] = [] }
      @commands = []
      @fail_after_first_create = false
      @fail_dependency_relation = false
      @task_find_returns_summaries = false
    end

    def run_json_command(*args)
      case args.first
      when "task-find"
        matches = @existing + @created
        return matches unless @task_find_returns_summaries

        matches.map { |task| task.merge("description" => "") }
      when "task-create"
        task = { "id" => 5301 + @created.size, "ref" => "A3-v2##{5301 + @created.size}", "title" => args[args.index("--title") + 1], "description" => "created" }
        @created << task
        task
      when "task-relation-list"
        task_id = args.fetch(args.index("--task-id") + 1).to_s
        @relations.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |command, grouped|
          next unless command.fetch(command.index("--task-id") + 1).to_s == task_id

          other_task_id = command.fetch(command.index("--other-task-id") + 1)
          relation_kind = command.fetch(command.index("--relation-kind") + 1)
          grouped[relation_kind] << { "id" => other_task_id.to_i, "ref" => ref_for_id(other_task_id) }
        end
      when "task-comment-list"
        task_id = args.fetch(args.index("--task-id") + 1)
        @comment_texts[task_id].map { |text| { "bodyMarkdown" => text } }
      else
        {}
      end
    end

    def run_json_command_with_text_file_option(*args, option_name:, text:, **)
      run_json_command(*args).tap { |task| task["description"] = text if task.is_a?(Hash) }
    end

    def run_command(*args)
      raise A3::Domain::ConfigurationError, "simulated label failure" if @fail_after_first_create && args.first == "task-label-add" && !args.include?("5301")
      raise A3::Domain::ConfigurationError, "simulated dependency failure" if @fail_dependency_relation && args.first == "task-relation-create" && args.include?("blocked")

      @commands << args
      @labels << args if args.first == "task-label-add"
      @relations << args if args.first == "task-relation-create"
      @comments << args if args.first == "task-comment-create"
      nil
    end

    def run_command_with_text_file_option(*args, text:, **)
      if args.first == "task-comment-create"
        task_id = args.fetch(args.index("--task-id") + 1)
        @comment_texts[task_id] << text
      end
      run_command(*args)
    end

    def fetch_task_by_ref(ref)
      (@created + @existing).find { |task| task.fetch("ref") == ref } || raise("missing #{ref}")
    end

    def ref_for_id(task_id)
      task = (@created + @existing).find { |item| item.fetch("id").to_s == task_id.to_s }
      task && task["ref"]
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

  def generated_parent(client)
    client.created.find { |task| task.fetch("description", "").include?("Decomposition source:") }
  end

  def generated_child(client, child_key = "child-key-1")
    (client.created + client.instance_variable_get(:@existing)).find { |task| task.fetch("description", "").include?("Child key: #{child_key}") }
  end

  it "creates a child with idempotency key, labels, trigger, and parent relation" do
    client = FakeProposalClient.new
    writer = described_class.new(project: "A3-v2", client: client)

    result = writer.call(parent_task_ref: "A3-v2#5300", parent_external_task_id: 5300, proposal_evidence: proposal_evidence)

    expect(result.success?).to be(true)
    expect(result.parent_ref).to eq("A3-v2#5301")
    expect(result.child_refs).to eq(["A3-v2#5302"])
    expect(result.child_keys).to eq(["child-key-1"])
    expect(generated_parent(client).fetch("description")).to include("Decomposition source: A3-v2#5300")
    expect(generated_child(client).fetch("description")).to include("Parent: A3-v2#5301")
    expect(generated_child(client).fetch("description")).to include("Child key: child-key-1")
    expect(generated_child(client).fetch("description")).to include("Proposal fingerprint: fp-1")
    expect(client.labels.any? { |args| args.include?("trigger:auto-implement") }).to be(true)
    expect(client.labels.any? { |args| args.include?("repo:alpha") }).to be(true)
    expect(client.relations).to include(
      array_including("task-relation-create", "--task-id", "5301", "--other-task-id", "5302", "--relation-kind", "subtask")
    )
    expect(client.relations).to include(
      array_including("task-relation-create", "--task-id", "5300", "--other-task-id", "5301", "--relation-kind", "related")
    )
    expect(client.comments.any? { |args| args.include?("5300") }).to be(true)
  end

  it "does not duplicate the source to generated parent related relation on reruns" do
    client = FakeProposalClient.new
    writer = described_class.new(project: "A3-v2", client: client, mode: :draft)

    first = writer.call(parent_task_ref: "A3-v2#5300", parent_external_task_id: 5300, proposal_evidence: proposal_evidence)
    second = writer.call(parent_task_ref: "A3-v2#5300", parent_external_task_id: 5300, proposal_evidence: proposal_evidence)

    expect(first.success?).to be(true)
    expect(second.success?).to be(true)
    related_relations = client.relations.select do |args|
      args.include?("--task-id") &&
        args.include?("5300") &&
        args.include?("--other-task-id") &&
        args.include?("5301") &&
        args.include?("--relation-kind") &&
        args.include?("related")
    end
    expect(related_relations.size).to eq(1)
  end

  it "reuses an existing child by child key even when proposal fingerprint changes" do
    existing = [
      { "id" => 5300, "ref" => "A3-v2#5300", "description" => "Decomposition source: A3-v2#5299" },
      { "id" => 5301, "ref" => "A3-v2#5301", "description" => "Child key: child-key-1\nProposal fingerprint: old" }
    ]
    client = FakeProposalClient.new(existing: existing)
    writer = described_class.new(project: "A3-v2", client: client)

    result = writer.call(parent_task_ref: "A3-v2#5300", parent_external_task_id: 5300, proposal_evidence: proposal_evidence(fingerprint: "new"))

    expect(result.success?).to be(true)
    expect(result.child_refs).to eq(["A3-v2#5301"])
    expect(client.created.size).to eq(1)
    expect(generated_parent(client).fetch("description")).to include("Decomposition source: A3-v2#5300")
    expect(client.labels.any? { |args| args.include?("trigger:auto-implement") }).to be(true)
  end

  it "hydrates task-find summaries before matching generated parent and child markers" do
    existing = [
      { "id" => 5301, "ref" => "A3-v2#5301", "description" => "Decomposition source: A3-v2#5300" },
      { "id" => 5302, "ref" => "A3-v2#5302", "description" => "Child key: child-key-1\nProposal fingerprint: old" }
    ]
    client = FakeProposalClient.new(existing: existing)
    client.task_find_returns_summaries = true
    writer = described_class.new(project: "A3-v2", client: client)

    result = writer.call(parent_task_ref: "A3-v2#5300", parent_external_task_id: 5300, proposal_evidence: proposal_evidence(fingerprint: "new"))

    expect(result.success?).to be(true)
    expect(result.parent_ref).to eq("A3-v2#5301")
    expect(result.child_refs).to eq(["A3-v2#5302"])
    expect(client.created).to eq([])
  end

  it "does not duplicate owned comments on reconciliation reruns" do
    client = FakeProposalClient.new
    writer = described_class.new(project: "A3-v2", client: client, mode: :draft)

    first = writer.call(parent_task_ref: "A3-v2#5300", parent_external_task_id: 5300, proposal_evidence: proposal_evidence)
    second = writer.call(parent_task_ref: "A3-v2#5300", parent_external_task_id: 5300, proposal_evidence: proposal_evidence)

    expect(first.success?).to be(true)
    expect(second.success?).to be(true)
    expect(client.comments.count { |args| args.include?("5300") }).to eq(1)
    expect(client.comments.count { |args| args.include?("5301") }).to eq(1)
    expect(client.comments.count { |args| args.include?("5302") }).to eq(1)
  end

  it "creates draft children without runnable trigger labels" do
    client = FakeProposalClient.new
    writer = described_class.new(project: "A3-v2", client: client, mode: :draft)
    payload = proposal_evidence
    payload["proposal"]["children"].first["labels"] = ["repo:alpha", "trigger:auto-implement"]

    result = writer.call(parent_task_ref: "A3-v2#5300", parent_external_task_id: 5300, proposal_evidence: payload)

    expect(result.success?).to be(true)
    expect(generated_child(client).fetch("description")).to include("Child key: child-key-1")
    expect(client.labels.any? { |args| args.include?("a2o:draft-child") }).to be(true)
    expect(client.labels.any? { |args| args.include?("a2o:decomposed") && args.include?("5300") }).to be(true)
    expect(client.labels.any? { |args| args.include?("a2o:decomposed") && args.include?("5301") }).to be(true)
    expect(client.labels.any? { |args| args.include?("repo:alpha") }).to be(true)
    expect(client.labels.any? { |args| args.include?("trigger:auto-implement") }).to be(false)
    expect(client.comments.any? { |args| args.include?("task-comment-create") }).to be(true)
  end

  it "creates non-runnable local draft children for a remote source without marking the source parent runnable" do
    client = FakeProposalClient.new
    writer = described_class.new(project: "Portal", client: client, mode: :draft)

    result = writer.call(parent_task_ref: "wamukat/a2o#16", parent_external_task_id: 240, proposal_evidence: proposal_evidence)

    expect(result.success?).to be(true)
    expect(result.parent_ref).to eq("A3-v2#5301")
    expect(result.child_refs).to eq(["A3-v2#5302"])
    expect(generated_parent(client).fetch("description")).to include("Decomposition source: wamukat/a2o#16")
    expect(generated_child(client).fetch("description")).to include("Parent: A3-v2#5301")
    expect(client.labels.any? { |args| args.include?("a2o:draft-child") }).to be(true)
    expect(client.labels.any? { |args| args.include?("trigger:auto-implement") }).to be(false)
    expect(client.labels.any? { |args| args.include?("trigger:auto-parent") }).to be(false)
    expect(client.relations).to include(
      array_including("task-relation-create", "--task-id", "5301", "--other-task-id", "5302", "--relation-kind", "subtask")
    )
    expect(client.comments.any? { |args| args.include?("240") }).to be(true)
  end

  it "filters proposed automation trigger labels from draft children" do
    client = FakeProposalClient.new
    writer = described_class.new(project: "Portal", client: client, mode: :draft)
    payload = proposal_evidence
    payload["proposal"]["children"].first["labels"] = ["repo:alpha", "trigger:auto-implement", "trigger:auto-parent"]

    result = writer.call(parent_task_ref: "wamukat/a2o#16", parent_external_task_id: 240, proposal_evidence: payload)

    expect(result.success?).to be(true)
    expect(client.labels.any? { |args| args.include?("a2o:draft-child") }).to be(true)
    expect(client.labels.any? { |args| args.include?("repo:alpha") }).to be(true)
    expect(client.labels.any? { |args| args.any? { |value| value.to_s.start_with?("trigger:") } }).to be(false)
  end

  it "reconciles draft children without overwriting existing edited content" do
    existing = [{ "id" => 5301, "ref" => "A3-v2#5301", "title" => "Human title", "description" => "Human body\nChild key: child-key-1" }]
    client = FakeProposalClient.new(existing: existing)
    writer = described_class.new(project: "A3-v2", client: client, mode: :draft)

    result = writer.call(parent_task_ref: "A3-v2#5300", parent_external_task_id: 5300, proposal_evidence: proposal_evidence(fingerprint: "new", title: "Generated title"))

    expect(result.success?).to be(true)
    expect(client.created.size).to eq(1)
    expect(generated_parent(client)).not_to be_nil
    expect(existing.first.fetch("title")).to eq("Human title")
    expect(existing.first.fetch("description")).to eq("Human body\nChild key: child-key-1")
    expect(client.labels.any? { |args| args.include?("a2o:draft-child") }).to be(true)
    expect(client.labels.any? { |args| args.include?("repo:alpha") }).to be(false)
    expect(client.labels.any? { |args| args.include?("trigger:auto-implement") }).to be(false)
  end

  it "preserves existing accepted draft children by not removing runnable labels" do
    existing = [{ "id" => 5301, "ref" => "A3-v2#5301", "description" => "Child key: child-key-1" }]
    client = FakeProposalClient.new(existing: existing)
    writer = described_class.new(project: "A3-v2", client: client, mode: :draft)

    result = writer.call(parent_task_ref: "A3-v2#5300", parent_external_task_id: 5300, proposal_evidence: proposal_evidence)

    expect(result.success?).to be(true)
    expect(client.commands.any? { |args| args.first == "task-label-remove" }).to be(false)
    expect(client.labels.any? { |args| args.include?("trigger:auto-implement") }).to be(false)
  end

  it "blocks reconciliation when duplicate children claim the same child key" do
    existing = [
      { "id" => 5301, "ref" => "A3-v2#5301", "description" => "Child key: child-key-1" },
      { "id" => 5302, "ref" => "A3-v2#5302", "description" => "Child key: child-key-1" }
    ]
    client = FakeProposalClient.new(existing: existing)
    writer = described_class.new(project: "A3-v2", client: client, mode: :draft)

    result = writer.call(parent_task_ref: "A3-v2#5300", parent_external_task_id: 5300, proposal_evidence: proposal_evidence)

    expect(result.success?).to be(false)
    expect(result.diagnostics.fetch("error")).to include("duplicate decomposition children for child key child-key-1")
    expect(result.diagnostics.fetch("error")).to include("A3-v2#5301(id=5301)")
    expect(result.diagnostics.fetch("error")).to include("A3-v2#5302(id=5302)")
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
    expect(client.relations.any? { |args| args.include?("blocked") }).to be(true)
  end

  it "returns already-created refs when a later reconciliation write fails" do
    client = FakeProposalClient.new
    client.fail_after_first_create = true
    writer = described_class.new(project: "A3-v2", client: client)

    result = writer.call(parent_task_ref: "A3-v2#5300", parent_external_task_id: 5300, proposal_evidence: proposal_evidence)

    expect(result.success?).to be(false)
    expect(result.child_refs).to eq(["A3-v2#5302"])
    expect(result.child_keys).to eq(["child-key-1"])
    expect(result.diagnostics.fetch("failed_write")).to include("child_key" => "child-key-1")
  end

  it "records dependency write failures with child and dependency context" do
    client = FakeProposalClient.new
    client.fail_dependency_relation = true
    writer = described_class.new(project: "A3-v2", client: client)
    payload = proposal_evidence
    payload["proposal"]["children"] << payload["proposal"]["children"].first.merge(
      "child_key" => "child-key-2",
      "title" => "Add review",
      "depends_on" => ["child-key-1"]
    )

    result = writer.call(parent_task_ref: "A3-v2#5300", parent_external_task_id: 5300, proposal_evidence: payload)

    expect(result.success?).to be(false)
    expect(result.child_refs).to eq(["A3-v2#5302", "A3-v2#5303"])
    expect(result.diagnostics.fetch("failed_write")).to include(
      "type" => "dependency",
      "child_key" => "child-key-2",
      "dependency_key" => "child-key-1",
      "child_ref" => "A3-v2#5303",
      "dependency_ref" => "A3-v2#5302"
    )
  end
end
