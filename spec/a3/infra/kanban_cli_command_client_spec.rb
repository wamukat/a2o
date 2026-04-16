# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Infra::KanbanCliCommandClient do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmp_dir = dir
      example.run
    end
  end

  let(:success_status) { instance_double(Process::Status, success?: true, exitstatus: 0) }

  it "runs JSON commands with text transported through a file option" do
    captured_path = nil
    allow(Open3).to receive(:capture3) do |*args|
      captured_path = args.each_cons(2).find { |flag, _value| flag == "--description-file" }&.last
      expect(File.read(captured_path)).to eq("line 1\nline 2")
      ['{"ok":true}', "", success_status]
    end

    client = described_class.new(command_argv: %w[task kanban:api --], project: "Sample", working_dir: @tmp_dir)

    payload = client.run_json_command_with_text_file_option(
      "task-create",
      "--project", "Sample",
      option_name: "--description",
      text: "line 1\nline 2",
      tempfile_prefix: "a3-description"
    )

    expect(payload).to eq("ok" => true)
    expect(captured_path).to start_with(@tmp_dir)
    expect(File.exist?(captured_path)).to be(false)
  end

  it "runs non-JSON commands with text transported through a file option" do
    captured_path = nil
    allow(Open3).to receive(:capture3) do |*args|
      captured_path = args.each_cons(2).find { |flag, _value| flag == "--comment-file" }&.last
      expect(File.read(captured_path)).to eq("comment\nbody")
      ["", "", success_status]
    end

    client = described_class.new(command_argv: %w[task kanban:api --], project: "Sample", working_dir: @tmp_dir)

    client.run_command_with_text_file_option(
      "task-comment-create",
      "--project", "Sample",
      option_name: "--comment",
      text: "comment\nbody",
      tempfile_prefix: "a3-comment"
    )

    expect(captured_path).to start_with(@tmp_dir)
    expect(File.exist?(captured_path)).to be(false)
  end
end

RSpec.describe A3::Infra::KanbanCommandClient do
  it "lets task adapters depend on the operation client without a subprocess argv" do
    recording_client = Class.new(described_class) do
      attr_reader :calls

      def initialize(project:)
        super
        @calls = []
      end

      def run_json_command(*args)
        @calls << args
        [{ "id" => 42, "ref" => "Sample#42", "title" => "Ticket", "status" => "To do" }]
      end
    end

    client = recording_client.new(project: "Sample")
    reader = A3::Infra::KanbanCliTaskSnapshotReader.new(project: "Sample", client: client)

    index = reader.load(task_refs: ["Sample#42"])

    expect(index.by_ref.fetch("Sample#42").fetch("title")).to eq("Ticket")
    expect(client.calls.fetch(0)).to eq(["task-watch-summary-list", "--project", "Sample", "--ignore-missing", "--task", "Sample#42"])
  end

  it "keeps write, label, comment, and relation contracts behind the operation client" do
    recording_client = Class.new(described_class) do
      attr_reader :json_calls, :command_calls, :comment_body, :created_description

      def initialize(project:)
        super
        @json_calls = []
        @command_calls = []
      end

      def run_json_command(*args)
        @json_calls << args
        case args.fetch(0)
        when "task-get"
          { "id" => 42, "ref" => "Sample#42", "title" => "Parent", "description" => "", "status" => "In progress" }
        when "task-label-list"
          [{ "title" => "blocked" }]
        when "task-find"
          []
        when "task-create"
          @created_description = File.read(args.each_cons(2).find { |flag, _value| flag == "--description-file" }.last)
          { "id" => 43, "ref" => "Sample#43", "title" => args.each_cons(2).find { |flag, _value| flag == "--title" }.last, "description" => @created_description }
        when "task-relation-list"
          { "parenttask" => [], "subtask" => [] }
        else
          raise "unexpected JSON command #{args.inspect}"
        end
      end

      def run_command(*args)
        @command_calls << args
        if args.fetch(0) == "task-comment-create"
          @comment_body = File.read(args.each_cons(2).find { |flag, _value| flag == "--comment-file" }.last)
        end
        nil
      end
    end

    client = recording_client.new(project: "Sample")

    status_publisher = A3::Infra::KanbanCliTaskStatusPublisher.new(project: "Sample", client: client)
    status_publisher.publish(task_ref: "Sample#42", status: :in_progress)
    status_publisher.publish(task_ref: "Sample#42", status: :blocked, external_task_id: 42)

    activity_publisher = A3::Infra::KanbanCliTaskActivityPublisher.new(project: "Sample", client: client)
    activity_publisher.publish(task_ref: "Sample#42", body: "review\ncomment", external_task_id: 42)

    disposition = A3::Domain::ReviewDisposition.new(
      kind: :follow_up_child,
      repo_scope: :repo_beta,
      summary: "contract coverage",
      description: "verify relation and labels",
      finding_key: "finding-contract"
    )
    child_writer = A3::Infra::KanbanCliFollowUpChildWriter.new(
      project: "Sample",
      repo_label_map: { "repo:ui-app" => ["repo_beta"] },
      follow_up_label: "a3:follow-up-child",
      client: client
    )
    result = child_writer.call(
      parent_task_ref: "Sample#42",
      parent_external_task_id: 42,
      review_run_ref: "review-run-1",
      disposition: disposition
    )

    expect(result.success?).to be(true)
    expect(client.json_calls).to include(["task-get", "--project", "Sample", "--task", "Sample#42"])
    expect(client.json_calls).to include(["task-label-list", "--project", "Sample", "--task-id", "42"])
    expect(client.json_calls).to include(["task-find", "--project", "Sample", "--query", "Sample#42|review-run-1|repo_beta|finding-contract"])
    expect(client.json_calls).to include(["task-relation-list", "--project", "Sample", "--task-id", "42"])
    expect(client.command_calls).to include(["task-label-remove", "--project", "Sample", "--task-id", "42", "--label", "blocked"])
    expect(client.command_calls).to include(["task-transition", "--project", "Sample", "--task-id", "42", "--status", "In progress"])
    expect(client.command_calls).to include(["task-label-add", "--project", "Sample", "--task-id", "42", "--label", "blocked"])
    expect(client.command_calls).to include(["task-transition", "--project", "Sample", "--task-id", "42", "--status", "To do"])
    expect(client.command_calls).to include(["label-ensure", "--project", "Sample", "--title", "repo:ui-app"])
    expect(client.command_calls).to include(["task-label-add", "--project", "Sample", "--task-id", "43", "--label", "repo:ui-app"])
    expect(client.command_calls).to include(["task-relation-create", "--project", "Sample", "--task-id", "42", "--other-task-id", "43", "--relation-kind", "subtask"])
    expect(client.command_calls.any? { |args| args.fetch(0) == "task-comment-create" && args.include?("--comment-file") }).to be(true)
    expect(client.comment_body).to eq("review\ncomment")
    expect(client.created_description).to include("Fingerprint: Sample#42|review-run-1|repo_beta|finding-contract")
  end
end
