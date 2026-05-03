# frozen_string_literal: true

RSpec.describe A3::Infra::KanbanCliDraftAcceptanceWriter do
  class FakeDraftAcceptanceClient
    attr_reader :commands, :comments, :json_calls
    attr_accessor :task_find_returns_summaries

    def initialize
      @tasks = {
        "Portal#240" => { "id" => 240, "ref" => "Portal#240" },
        "Portal#241" => { "id" => 241, "ref" => "Portal#241", "title" => "Human title", "description" => "Human body" },
        "Portal#242" => { "id" => 242, "ref" => "Portal#242" },
        "Portal#243" => { "id" => 243, "ref" => "Portal#243", "description" => "" },
        "Portal#244" => { "id" => 244, "ref" => "Portal#244" },
        "Portal#999" => { "id" => 999, "ref" => "Portal#999" }
      }
      @tasks_by_id = @tasks.values.each_with_object({}) { |task, memo| memo[task.fetch("id")] = task }
      @labels = {
        240 => ["trigger:investigate"],
        241 => ["a2o:draft-child", "a2o:ready-child", "repo:portal"],
        242 => ["a2o:draft-child", "repo:admin"],
        243 => [],
        244 => ["a2o:draft-child", "repo:generated"],
        999 => ["a2o:draft-child"]
      }
      @relations = {
        240 => { "subtask" => [{ "ref" => "Portal#241" }, { "ref" => "Portal#242" }], "related" => [] },
        243 => { "subtask" => [{ "ref" => "Portal#244" }], "related" => [] }
      }
      @commands = []
      @comments = []
      @json_calls = []
      @task_find_returns_summaries = false
    end

    def fetch_task_by_id(task_id)
      @tasks_by_id.fetch(Integer(task_id))
    end

    def fetch_task_by_ref(ref)
      @tasks.fetch(ref)
    end

    def load_task_labels(task_id)
      @labels.fetch(Integer(task_id))
    end

    def run_json_command(*args)
      @json_calls << args
      if args.first == "task-find"
        query = args.fetch(args.index("--query") + 1)
        matches = @tasks.values.select { |task| task.fetch("description", "").include?("Decomposition source: #{query}") }
        return matches.map { |task| task.merge("description" => "") } if @task_find_returns_summaries

        return matches
      end
      return @relations.fetch(Integer(args.fetch(args.index("--task-id") + 1)), {}) if args.first == "task-relation-list"

      {}
    end

    def run_command(*args)
      @commands << args
      if args.first == "task-label-add"
        @labels.fetch(Integer(args[args.index("--task-id") + 1])) << args.fetch(args.index("--label") + 1)
      elsif args.first == "task-label-remove"
        @labels.fetch(Integer(args[args.index("--task-id") + 1])).delete(args.fetch(args.index("--label") + 1))
      end
      nil
    end

    def run_command_with_text_file_option(*args, text:, **)
      @comments << [args, text]
      run_command(*args)
    end

    def labels_for(task_id)
      @labels.fetch(Integer(task_id))
    end
  end

  it "accepts only selected ready draft children without changing unselected drafts" do
    client = FakeDraftAcceptanceClient.new
    writer = described_class.new(project: "Portal", client: client)

    result = writer.call(parent_task_ref: "Portal#240", parent_external_task_id: 240, ready_only: true)

    expect(result.success?).to be(true)
    expect(result.accepted_refs).to eq(["Portal#241"])
    expect(result.skipped_refs).to eq(["Portal#242"])
    expect(client.labels_for(241)).to include("trigger:auto-implement")
    expect(client.labels_for(241)).to include("a2o:draft-child")
    expect(client.labels_for(242)).not_to include("trigger:auto-implement")
    expect(client.labels_for(240)).to include("trigger:auto-parent", "repo:portal")
    expect(client.labels_for(240)).not_to include("repo:admin")
    expect(client.commands.none? { |args| args.first == "task-create" }).to be(true)
    expect(client.comments.size).to eq(2)
  end

  it "is idempotent and does not duplicate comments when labels already exist" do
    client = FakeDraftAcceptanceClient.new
    client.labels_for(241) << "trigger:auto-implement"
    writer = described_class.new(project: "Portal", client: client)

    result = writer.call(parent_task_ref: "Portal#240", parent_external_task_id: 240, child_refs: ["Portal#241"])

    expect(result.success?).to be(true)
    expect(result.accepted_refs).to eq(["Portal#241"])
    expect(client.labels_for(240)).to include("trigger:auto-parent", "repo:portal")
    expect(client.comments.size).to eq(1)
    expect(client.commands.none? { |args| args.first == "task-label-add" && args.include?("trigger:auto-implement") }).to be(true)
  end

  it "skips explicitly selected draft children that are not related to the parent" do
    client = FakeDraftAcceptanceClient.new
    writer = described_class.new(project: "Portal", client: client)

    result = writer.call(
      parent_task_ref: "Portal#240",
      parent_external_task_id: 240,
      child_refs: ["Portal#999"],
      parent_auto: true
    )

    expect(result.success?).to be(true)
    expect(result.accepted_refs).to eq([])
    expect(result.skipped_refs).to eq(["Portal#999"])
    expect(result.parent_automation_applied).to be(false)
    expect(client.labels_for(999)).not_to include("trigger:auto-implement")
    expect(client.labels_for(240)).not_to include("trigger:auto-parent")
    expect(client.comments).to eq([])
  end

  it "removes draft labels and applies parent automation with accepted child repo labels" do
    client = FakeDraftAcceptanceClient.new
    writer = described_class.new(project: "Portal", client: client)

    result = writer.call(
      parent_task_ref: "Portal#240",
      parent_external_task_id: 240,
      child_refs: ["Portal#241"],
      remove_draft_label: true,
      parent_auto: true
    )

    expect(result.parent_automation_applied).to be(true)
    expect(client.labels_for(241)).to include("trigger:auto-implement")
    expect(client.labels_for(241)).not_to include("a2o:draft-child")
    expect(client.labels_for(240)).to include("trigger:auto-parent", "repo:portal")
    expect(client.labels_for(240)).not_to include("repo:admin")
    expect(client.labels_for(240)).not_to include("trigger:investigate")
    expect(client.comments.size).to eq(2)
  end

  it "can accept children without enabling parent automation when explicitly disabled" do
    client = FakeDraftAcceptanceClient.new
    writer = described_class.new(project: "Portal", client: client)

    result = writer.call(
      parent_task_ref: "Portal#240",
      parent_external_task_id: 240,
      child_refs: ["Portal#241"],
      parent_auto: false
    )

    expect(result.success?).to be(true)
    expect(result.accepted_refs).to eq(["Portal#241"])
    expect(result.parent_automation_applied).to be(false)
    expect(client.labels_for(241)).to include("trigger:auto-implement")
    expect(client.labels_for(240)).not_to include("trigger:auto-parent", "repo:portal")
  end

  it "accepts generated-parent children when invoked with the requirement source ticket" do
    client = FakeDraftAcceptanceClient.new
    client.fetch_task_by_ref("Portal#243")["description"] = "Decomposition source: Portal#240"
    client.task_find_returns_summaries = true
    writer = described_class.new(project: "Portal", client: client)

    result = writer.call(
      parent_task_ref: "Portal#240",
      parent_external_task_id: 240,
      child_refs: ["Portal#244"],
      parent_auto: true
    )

    expect(result.success?).to be(true)
    expect(result.accepted_refs).to eq(["Portal#244"])
    expect(client.labels_for(244)).to include("trigger:auto-implement")
    expect(client.labels_for(243)).to include("trigger:auto-parent", "repo:generated")
    expect(client.labels_for(240)).not_to include("trigger:auto-parent")
  end

  it "does not alter child title or description" do
    client = FakeDraftAcceptanceClient.new
    child_before = client.fetch_task_by_ref("Portal#241").dup
    writer = described_class.new(project: "Portal", client: client)

    writer.call(parent_task_ref: "Portal#240", parent_external_task_id: 240, child_refs: ["Portal#241"])

    child_after = client.fetch_task_by_ref("Portal#241")
    expect(child_after.fetch("title")).to eq(child_before.fetch("title"))
    expect(child_after.fetch("description")).to eq(child_before.fetch("description"))
  end
end
