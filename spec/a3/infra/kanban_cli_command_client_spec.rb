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
end
