# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Infra::KanbanCliTaskActivityPublisher do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmp_dir = dir
      example.run
    end
  end

  it "creates a comment for the canonical task ref" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 5001,
          "ref" => "Sample#5001",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
          "parent_ref" => nil
        }
      ]
    )

    publisher = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      publisher.publish(task_ref: "Sample#5001", body: "A3 started implementation\nwith details")
    end

    comments = read_fake_kanban_comments(fake_cli.fetch(:comments_path))
    expect(comments.fetch("5001").fetch(0).fetch("comment")).to eq("A3 started implementation\nwith details")
  end

  it "rejects non-canonical task refs" do
    publisher = described_class.new(command_argv: ["ruby", "fake"], project: "Sample", working_dir: @tmp_dir)

    expect { publisher.publish(task_ref: "5001", body: "bad") }
      .to raise_error(A3::Domain::ConfigurationError, /canonical Project#N/)
  end

  it "retains command argv for downstream follow-up child wiring" do
    publisher = described_class.new(command_argv: ["task", "kanban:api", "--"], project: "Sample", working_dir: @tmp_dir)

    expect(publisher.command_argv).to eq(["task", "kanban:api", "--"])
  end

  it "appends multiple comments for the same task" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 5002,
          "ref" => "Sample#5002",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
          "parent_ref" => nil
        }
      ]
    )

    publisher = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      publisher.publish(task_ref: "Sample#5002", body: "A3-v2 started implementation")
      publisher.publish(task_ref: "Sample#5002", body: "A3-v2 completed implementation")
    end

    comments = read_fake_kanban_comments(fake_cli.fetch(:comments_path)).fetch("5002")
    expect(comments.map { |item| item.fetch("comment") }).to eq(
      ["A3-v2 started implementation", "A3-v2 completed implementation"]
    )
  end

  it "resolves the external task id from the canonical reference when task id differs" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 5003,
          "ref" => "Sample#5002",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
          "parent_ref" => nil
        }
      ]
    )

    publisher = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      publisher.publish(task_ref: "Sample#5002", body: "A3-v2 started implementation")
    end

    comments = read_fake_kanban_comments(fake_cli.fetch(:comments_path)).fetch("5003")
    expect(comments.map { |item| item.fetch("comment") }).to eq(["A3-v2 started implementation"])
  end

  it "prefers the imported external task id when duplicate references exist" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 5002,
          "ref" => "Sample#5002",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
          "parent_ref" => nil
        },
        {
          "id" => 5003,
          "ref" => "Sample#5002",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
          "parent_ref" => nil
        }
      ]
    )

    publisher = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      publisher.publish(task_ref: "Sample#5002", external_task_id: 5003, body: "A3-v2 started implementation")
    end

    comments = read_fake_kanban_comments(fake_cli.fetch(:comments_path)).fetch("5003")
    expect(comments.map { |item| item.fetch("comment") }).to eq(["A3-v2 started implementation"])
  end
end
