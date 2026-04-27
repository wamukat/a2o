# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Infra::KanbanCliTaskStatusPublisher do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmp_dir = dir
      example.run
    end
  end

  it "transitions the external task to the mapped kanban status" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 3046,
          "ref" => "Sample#3046",
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
      publisher.publish(task_ref: "Sample#3046", status: :in_progress)
    end

    transitions = read_fake_kanban_transitions(fake_cli.fetch(:transitions_path))
    expect(transitions.size).to eq(1)
    expect(transitions.fetch(0).fetch("argv")).to include("task-transition", "--task-id", "3046", "--status", "In progress")
  end

  it "resolves the task id via task-get instead of task-snapshot-list" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 3049,
          "ref" => "Sample#3049",
          "status" => "Inspection",
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
      publisher.publish(task_ref: "Sample#3049", status: :done)
    end

    transitions = read_fake_kanban_transitions(fake_cli.fetch(:transitions_path))
    expect(transitions.fetch(0).fetch("argv")).to include("task-transition", "--task-id", "3049", "--status", "Done")
  end

  it "adds the blocked label and returns the task to To do when publishing blocked" do
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
      publisher.publish(task_ref: "Sample#5001", status: :blocked)
    end

    transitions = read_fake_kanban_transitions(fake_cli.fetch(:transitions_path))
    expect(transitions.size).to eq(2)
    expect(transitions.fetch(0).fetch("argv")).to include("task-label-add", "--task-id", "5001", "--label", "blocked")
    expect(transitions.fetch(1).fetch("argv")).to include("task-transition", "--task-id", "5001", "--status", "To do")
  end

  it "adds the clarification label and returns the task to To do when publishing needs_clarification" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 5004,
          "ref" => "Sample#5004",
          "status" => "In review",
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
      publisher.publish(task_ref: "Sample#5004", status: :needs_clarification)
    end

    transitions = read_fake_kanban_transitions(fake_cli.fetch(:transitions_path))
    expect(transitions.size).to eq(2)
    expect(transitions.fetch(0).fetch("argv")).to include("task-label-add", "--task-id", "5004", "--label", "needs:clarification")
    expect(transitions.fetch(1).fetch("argv")).to include("task-transition", "--task-id", "5004", "--status", "To do")
  end

  it "clears a stale blocked label before transitioning back to an active status" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 5002,
          "ref" => "Sample#5002",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-implement", "blocked"],
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
      publisher.publish(task_ref: "Sample#5002", status: :in_progress)
    end

    transitions = read_fake_kanban_transitions(fake_cli.fetch(:transitions_path))
    expect(transitions.size).to eq(2)
    expect(transitions.fetch(0).fetch("argv")).to include("task-label-remove", "--task-id", "5002", "--label", "blocked")
    expect(transitions.fetch(1).fetch("argv")).to include("task-transition", "--task-id", "5002", "--status", "In progress")
  end

  it "clears stale clarification labels before transitioning back to an active status" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 5005,
          "ref" => "Sample#5005",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-implement", "needs:clarification"],
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
      publisher.publish(task_ref: "Sample#5005", status: :in_progress)
    end

    transitions = read_fake_kanban_transitions(fake_cli.fetch(:transitions_path))
    expect(transitions.size).to eq(2)
    expect(transitions.fetch(0).fetch("argv")).to include("task-label-remove", "--task-id", "5005", "--label", "needs:clarification")
    expect(transitions.fetch(1).fetch("argv")).to include("task-transition", "--task-id", "5005", "--status", "In progress")
  end

  it "publishes child in_review as In review" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 5003,
          "ref" => "Sample#5003",
          "status" => "In progress",
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
      publisher.publish(task_ref: "Sample#5003", status: :in_review, task_kind: :child)
    end

    transitions = read_fake_kanban_transitions(fake_cli.fetch(:transitions_path))
    expect(transitions.fetch(0).fetch("argv")).to include("task-transition", "--task-id", "5003", "--status", "In review")
  end

  it "derives the task id from a canonical task ref when available" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 4100,
          "ref" => "Sample#4100",
          "status" => "Merging",
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
      publisher.publish(task_ref: "Sample#4100", status: :done)
    end

    transitions = read_fake_kanban_transitions(fake_cli.fetch(:transitions_path))
    expect(transitions.fetch(0).fetch("argv")).to include("task-transition", "--task-id", "4100", "--status", "Done")
  end

  it "resolves the external task id from the canonical reference when task id differs" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 4101,
          "ref" => "Sample#4100",
          "status" => "Merging",
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
      publisher.publish(task_ref: "Sample#4100", status: :done)
    end

    transitions = read_fake_kanban_transitions(fake_cli.fetch(:transitions_path))
    expect(transitions.fetch(0).fetch("argv")).to include("task-transition", "--task-id", "4101", "--status", "Done")
  end

  it "prefers the imported external task id when duplicate references exist" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 4100,
          "ref" => "Sample#4100",
          "status" => "Merging",
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
          "parent_ref" => nil
        },
        {
          "id" => 4101,
          "ref" => "Sample#4100",
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
      publisher.publish(task_ref: "Sample#4100", external_task_id: 4101, status: :done)
    end

    transitions = read_fake_kanban_transitions(fake_cli.fetch(:transitions_path))
    expect(transitions.fetch(0).fetch("argv")).to include("task-transition", "--task-id", "4101", "--status", "Done")
  end

  it "rejects non-canonical task refs" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 4100,
          "ref" => "Sample#4100",
          "status" => "Merging",
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
      expect { publisher.publish(task_ref: "4100", status: :done) }
        .to raise_error(A3::Domain::ConfigurationError, /canonical Project#N/)
    end
  end
end
