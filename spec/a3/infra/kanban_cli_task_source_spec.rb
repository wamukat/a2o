# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Infra::KanbanCliTaskSource do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmp_dir = dir
      example.run
    end
  end

  it "imports trigger-matched tasks and maps labels to repo scopes" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      task_get_includes_labels: false,
      snapshots: [
        {
          "id" => 3046,
          "ref" => "Sample#3046",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
          "parent_ref" => nil
        },
        {
          "id" => 3045,
          "ref" => "Sample#3045",
          "status" => "Backlog",
          "labels" => ["repo:both", "trigger:auto-implement"],
          "parent_ref" => nil
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:ui-app" => [:repo_beta],
        "repo:both" => %i[repo_alpha repo_beta]
      },
      trigger_labels: ["trigger:auto-implement"],
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      tasks = source.load

      expect(tasks.map(&:ref)).to eq(["Sample#3046"])
      expect(tasks.fetch(0).kind).to eq(:single)
      expect(tasks.fetch(0).edit_scope).to eq([:repo_beta])
      expect(tasks.fetch(0).status).to eq(:todo)
      expect(tasks.fetch(0).external_task_id).to eq(3046)
    end
  end

  it "builds parent tasks when imported snapshots reference them as children" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 4000,
          "ref" => "Sample#4000",
          "status" => "In progress",
          "labels" => ["repo:both", "trigger:auto-implement"],
          "parent_ref" => nil
        },
        {
          "id" => 4001,
          "ref" => "Sample#4001",
          "status" => "Done",
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
          "parent_ref" => "Sample#4000"
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:ui-app" => [:repo_beta],
        "repo:both" => %i[repo_alpha repo_beta]
      },
      trigger_labels: ["trigger:auto-implement"],
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      tasks = source.load
      parent = tasks.find { |task| task.ref == "Sample#4000" }
      child = tasks.find { |task| task.ref == "Sample#4001" }

      expect(parent.kind).to eq(:parent)
      expect(parent.child_refs).to eq(["Sample#4001"])
      expect(child.parent_ref).to eq("Sample#4000")
    end
  end

  it "treats multiple trigger labels as any-match" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 3036,
          "ref" => "Sample#3036",
          "status" => "To do",
          "labels" => ["repo:both", "trigger:auto-parent"],
          "parent_ref" => nil
        },
        {
          "id" => 3037,
          "ref" => "Sample#3037",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
          "parent_ref" => "Sample#3036"
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:ui-app" => [:repo_beta],
        "repo:both" => %i[repo_alpha repo_beta]
      },
      trigger_labels: ["trigger:auto-implement", "trigger:auto-parent"],
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      tasks = source.load

      expect(tasks.map(&:ref)).to include("Sample#3036", "Sample#3037")
      expect(tasks.find { |task| task.ref == "Sample#3036" }.kind).to eq(:parent)
      expect(tasks.find { |task| task.ref == "Sample#3037" }.kind).to eq(:child)
    end
  end

  it "passes through a kanban status filter when configured" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 5001,
          "ref" => "Sample#5001",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-scheduler-canary"],
          "parent_ref" => nil
        },
        {
          "id" => 5002,
          "ref" => "Sample#5002",
          "status" => "Done",
          "labels" => ["repo:ui-app", "trigger:auto-scheduler-canary"],
          "parent_ref" => nil
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:ui-app" => [:repo_beta]
      },
      trigger_labels: ["trigger:auto-scheduler-canary"],
      status: "To do",
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      tasks = source.load

      expect(tasks.map(&:ref)).to eq(["Sample#5001"])
    end
  end

  it "preserves parent topology from the unfiltered graph even when children are outside the selection status" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 5100,
          "ref" => "Sample#5100",
          "status" => "To do",
          "labels" => ["repo:both", "trigger:auto-parent"],
          "parent_ref" => nil
        },
        {
          "id" => 5101,
          "ref" => "Sample#5101",
          "status" => "In review",
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
          "parent_ref" => "Sample#5100"
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:ui-app" => [:repo_beta],
        "repo:both" => %i[repo_alpha repo_beta]
      },
      trigger_labels: ["trigger:auto-implement", "trigger:auto-parent"],
      status: "To do",
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      tasks = source.load
      parent = tasks.find { |task| task.ref == "Sample#5100" }
      child = tasks.find { |task| task.ref == "Sample#5101" }

      expect(tasks.map(&:ref)).to eq(["Sample#5100", "Sample#5101"])
      expect(parent.kind).to eq(:parent)
      expect(parent.child_refs).to eq(["Sample#5101"])
      expect(child.status).to eq(:verifying)
      expect(child.parent_ref).to eq("Sample#5100")
    end
  end

  it "imports done children from kanban topology so parent gates use kanban as the master state" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 5200,
          "ref" => "Sample#5200",
          "status" => "To do",
          "labels" => ["repo:both", "trigger:auto-parent"],
          "parent_ref" => nil
        },
        {
          "id" => 5201,
          "ref" => "Sample#5201",
          "status" => "Done",
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
          "parent_ref" => "Sample#5200"
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:ui-app" => [:repo_beta],
        "repo:both" => %i[repo_alpha repo_beta]
      },
      trigger_labels: ["trigger:auto-implement", "trigger:auto-parent"],
      status: "To do",
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      tasks = source.load
      parent = tasks.find { |task| task.ref == "Sample#5200" }
      child = tasks.find { |task| task.ref == "Sample#5201" }

      expect(parent.child_refs).to eq(["Sample#5201"])
      expect(child.status).to eq(:done)
    end
  end

  it "imports connected topology even when a related task lacks trigger labels" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 5300,
          "ref" => "Sample#5300",
          "status" => "To do",
          "labels" => ["repo:both", "trigger:auto-parent"],
          "parent_ref" => nil
        },
        {
          "id" => 5301,
          "ref" => "Sample#5301",
          "status" => "Done",
          "labels" => ["repo:ui-app"],
          "parent_ref" => "Sample#5300"
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:ui-app" => [:repo_beta],
        "repo:both" => %i[repo_alpha repo_beta]
      },
      trigger_labels: ["trigger:auto-parent"],
      status: "To do",
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      tasks = source.load
      parent = tasks.find { |task| task.ref == "Sample#5300" }
      child = tasks.find { |task| task.ref == "Sample#5301" }

      expect(tasks.map(&:ref)).to eq(["Sample#5300", "Sample#5301"])
      expect(parent.child_refs).to eq(["Sample#5301"])
      expect(child.status).to eq(:done)
    end
  end

  it "can fetch a single task by external id without applying the status filter" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 5001,
          "ref" => "Sample#5001",
          "status" => "In review",
          "labels" => ["repo:ui-app", "trigger:auto-scheduler-canary"],
          "parent_ref" => nil
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:ui-app" => [:repo_beta]
      },
      trigger_labels: ["trigger:auto-scheduler-canary"],
      status: "To do",
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      task = source.fetch_by_external_task_id(5001)

      expect(task.ref).to eq("Sample#5001")
      expect(task.status).to eq(:verifying)
      expect(task.edit_scope).to eq([:repo_beta])
      expect(task.child_refs).to eq([])
      expect(task.external_task_id).to eq(5001)
    end
  end

  it "can fetch a task packet with title and description for worker requests" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 3153,
          "ref" => "Sample#3153",
          "title" => "Migrate persistence from JDBC to MyBatis",
          "description" => "Replace the JDBC implementation with a MyBatis-backed one.",
          "status" => "In progress",
          "labels" => ["repo:alpha", "trigger:auto-implement"],
          "parent_ref" => nil
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:alpha" => [:repo_alpha]
      },
      trigger_labels: ["trigger:auto-implement"],
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      packet = source.fetch_task_packet_by_external_task_id(3153)

      expect(packet).to include(
        "task_id" => 3153,
        "ref" => "Sample#3153",
        "title" => "Migrate persistence from JDBC to MyBatis",
        "description" => "Replace the JDBC implementation with a MyBatis-backed one.",
        "status" => "In progress",
        "labels" => ["repo:alpha", "trigger:auto-implement"]
      )
    end
  end

  it "matches blocked selection against canonical blocked status even when raw kanban status remains To do" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 5400,
          "ref" => "Sample#5400",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-scheduler-canary", "blocked"],
          "parent_ref" => nil
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:ui-app" => [:repo_beta]
      },
      trigger_labels: ["trigger:auto-scheduler-canary"],
      status: "Blocked",
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      tasks = source.load

      expect(tasks.map(&:ref)).to eq(["Sample#5400"])
      expect(tasks.fetch(0).status).to eq(:blocked)
    end
  end

  it "does not leak blocked tasks into the raw To do selection" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 5401,
          "ref" => "Sample#5401",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-scheduler-canary", "blocked"],
          "parent_ref" => nil
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:ui-app" => [:repo_beta]
      },
      trigger_labels: ["trigger:auto-scheduler-canary"],
      status: "To do",
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      expect(source.load).to eq([])
    end
  end
end
