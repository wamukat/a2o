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
          "priority" => 4,
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
      expect(tasks.fetch(0).priority).to eq(4)
      expect(tasks.fetch(0).external_task_id).to eq(3046)
      expect(tasks.fetch(0).labels).to eq(["repo:ui-app", "trigger:auto-implement"])
    end
  end

  it "skips decomposed source tickets before requiring a repo scope label" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      task_get_includes_labels: false,
      snapshots: [
        {
          "id" => 3048,
          "ref" => "Sample#3048",
          "status" => "To do",
          "priority" => 3,
          "labels" => ["trigger:investigate", "a2o:decomposed"],
          "parent_ref" => nil
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:api" => [:repo_alpha],
        "repo:ui-app" => [:repo_beta]
      },
      trigger_labels: ["trigger:investigate"],
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      expect(source.load).to eq([])
    end
  end

  it "imports trigger-investigate source tickets without repo scope labels" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      task_get_includes_labels: false,
      snapshots: [
        {
          "id" => 3050,
          "ref" => "Sample#3050",
          "status" => "To do",
          "priority" => 3,
          "labels" => ["trigger:investigate"],
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
      trigger_labels: ["trigger:investigate"],
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      tasks = source.load

      expect(tasks.map(&:ref)).to eq(["Sample#3050"])
      expect(tasks.fetch(0).edit_scope).to eq([])
      expect(tasks.fetch(0).labels).to eq(["trigger:investigate"])
    end
  end

  it "keeps implementation-triggered tasks strict when repo scope labels are missing" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      task_get_includes_labels: false,
      snapshots: [
        {
          "id" => 3051,
          "ref" => "Sample#3051",
          "status" => "To do",
          "priority" => 3,
          "labels" => ["trigger:auto-implement"],
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
      trigger_labels: ["trigger:auto-implement"],
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      expect { source.load }.to raise_error(A3::Domain::ConfigurationError, /has no repo label/)
    end
  end

  it "does not hide decomposed parents selected by parent automation trigger" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      task_get_includes_labels: false,
      snapshots: [
        {
          "id" => 3049,
          "ref" => "Sample#3049",
          "status" => "To do",
          "priority" => 3,
          "labels" => ["repo:ui-app", "trigger:auto-parent", "a2o:decomposed"],
          "parent_ref" => nil
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:api" => [:repo_alpha],
        "repo:ui-app" => [:repo_beta]
      },
      trigger_labels: ["trigger:auto-parent"],
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      tasks = source.load

      expect(tasks.map(&:ref)).to eq(["Sample#3049"])
      expect(tasks.fetch(0).edit_scope).to eq([:repo_beta])
    end
  end

  it "imports unscoped decomposed parents selected by parent automation trigger" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      task_get_includes_labels: false,
      snapshots: [
        {
          "id" => 3052,
          "ref" => "Sample#3052",
          "status" => "To do",
          "priority" => 3,
          "labels" => ["trigger:auto-parent", "a2o:decomposed"],
          "parent_ref" => nil
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:api" => [:repo_alpha],
        "repo:ui-app" => [:repo_beta]
      },
      trigger_labels: ["trigger:auto-parent"],
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      tasks = source.load

      expect(tasks.map(&:ref)).to eq(["Sample#3052"])
      expect(tasks.fetch(0).edit_scope).to eq(%i[repo_alpha repo_beta])
      expect(tasks.fetch(0).repo_scope_key).to eq(:both)
      expect(tasks.fetch(0).labels).to eq(["trigger:auto-parent", "a2o:decomposed"])
    end
  end

  it "maps clarification-labeled tasks to needs_clarification" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      task_get_includes_labels: false,
      snapshots: [
        {
          "id" => 3047,
          "ref" => "Sample#3047",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-implement", "needs:clarification"],
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
      trigger_labels: ["trigger:auto-implement"],
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      tasks = source.load

      expect(tasks.fetch(0).status).to eq(:needs_clarification)
      expect(tasks.fetch(0).runnable_phase).to be_nil
    end
  end

  it "excludes resolved done-lane tasks from the imported set" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 7001,
          "ref" => "Sample#7001",
          "status" => "Done",
          "done" => true,
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
          "parent_ref" => nil
        },
        {
          "id" => 7002,
          "ref" => "Sample#7002",
          "status" => "Done",
          "done" => false,
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
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
      trigger_labels: ["trigger:auto-implement"],
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      tasks = source.load

      expect(tasks.map(&:ref)).to eq(["Sample#7002"])
    end
  end

  it "excludes archived tasks from the imported set" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 7051,
          "ref" => "Sample#7051",
          "status" => "To do",
          "is_archived" => true,
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
          "parent_ref" => nil
        },
        {
          "id" => 7052,
          "ref" => "Sample#7052",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
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
      trigger_labels: ["trigger:auto-implement"],
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      tasks = source.load

      expect(tasks.map(&:ref)).to eq(["Sample#7052"])
    end
  end

  it "does not keep resolved done-lane children in parent topology" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 7100,
          "ref" => "Sample#7100",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
          "parent_ref" => nil
        },
        {
          "id" => 7101,
          "ref" => "Sample#7101",
          "status" => "Done",
          "done" => true,
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
          "parent_ref" => "Sample#7100"
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:ui-app" => [:repo_beta]
      },
      trigger_labels: ["trigger:auto-implement"],
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      tasks = source.load
      parent = tasks.find { |task| task.ref == "Sample#7100" }

      expect(tasks.map(&:ref)).to eq(["Sample#7100"])
      expect(parent.kind).to eq(:single)
      expect(parent.child_refs).to eq([])
    end
  end

  it "does not keep archived children in parent topology" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 7150,
          "ref" => "Sample#7150",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
          "parent_ref" => nil
        },
        {
          "id" => 7151,
          "ref" => "Sample#7151",
          "status" => "To do",
          "is_archived" => true,
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
          "parent_ref" => "Sample#7150"
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:ui-app" => [:repo_beta]
      },
      trigger_labels: ["trigger:auto-implement"],
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      tasks = source.load
      parent = tasks.find { |task| task.ref == "Sample#7150" }

      expect(tasks.map(&:ref)).to eq(["Sample#7150"])
      expect(parent.kind).to eq(:single)
      expect(parent.child_refs).to eq([])
    end
  end

  it "does not keep archived blockers in task topology" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 8000,
          "ref" => "Sample#8000",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
          "blocking_task_refs" => ["Sample#8001"]
        },
        {
          "id" => 8001,
          "ref" => "Sample#8001",
          "status" => "To do",
          "is_archived" => true,
          "labels" => ["repo:ui-app", "trigger:auto-implement"]
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:ui-app" => [:repo_beta]
      },
      trigger_labels: ["trigger:auto-implement"],
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      tasks = source.load
      task = tasks.find { |candidate| candidate.ref == "Sample#8000" }

      expect(tasks.map(&:ref)).to eq(["Sample#8000"])
      expect(task.blocking_task_refs).to eq([])
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

  it "fails with an actionable diagnostic when trigger-matched labels do not map to repo scopes" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 3038,
          "ref" => "Sample#3038",
          "status" => "To do",
          "labels" => ["repo:both", "trigger:auto-parent"],
          "parent_ref" => nil
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:starters" => [:repo_alpha],
        "repo:ui-app" => [:repo_beta]
      },
      trigger_labels: ["trigger:auto-parent"],
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      expect { source.load }.to raise_error(
        A3::Domain::ConfigurationError,
        /Sample#3038.*repo:both.*repo:starters, repo:ui-app.*add one or more configured repo labels/
      )
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
          "labels" => ["repo:ui-app", "trigger:auto-scheduler-validation"],
          "parent_ref" => nil
        },
        {
          "id" => 5002,
          "ref" => "Sample#5002",
          "status" => "Done",
          "labels" => ["repo:ui-app", "trigger:auto-scheduler-validation"],
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
      trigger_labels: ["trigger:auto-scheduler-validation"],
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
      expect(child.status).to eq(:in_review)
      expect(child.parent_ref).to eq("Sample#5100")
    end
  end

  it "keeps parent child_refs when an unresolved backlog child is hidden from the execution-lane selection" do
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
          "status" => "Backlog",
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

      expect(tasks.map(&:ref)).to eq(["Sample#5200"])
      expect(parent.kind).to eq(:parent)
      expect(parent.child_refs).to eq(["Sample#5201"])
    end
  end

  it "keeps topology when relation payload omits child status" do
    client = Class.new do
      def run_json_command(*args)
        command = args.fetch(0)
        case command
        when "task-snapshot-list"
          [
            {
              "id" => 5100,
              "ref" => "Sample#5100",
              "status" => "To do",
              "labels" => ["repo:both", "trigger:auto-parent"],
              "parent_ref" => nil
            }
          ]
        when "task-relation-list"
          task_id = Integer(args[args.index("--task-id") + 1])
          case task_id
          when 5100
            {
              "parenttask" => [],
              "subtask" => [
                {
                  "id" => 5101,
                  "ref" => "Sample#5101"
                }
              ]
            }
          when 5101
            {
              "parenttask" => [
                {
                  "id" => 5100,
                  "ref" => "Sample#5100"
                }
              ],
              "subtask" => []
            }
          else
            raise "unexpected relation task id: #{task_id}"
          end
        else
          raise "unexpected command: #{args.inspect}"
        end
      end

      def fetch_task_by_id(task_id)
        case Integer(task_id)
        when 5100
          {
            "id" => 5100,
            "ref" => "Sample#5100",
            "status" => "To do",
            "labels" => ["repo:both", "trigger:auto-parent"]
          }
        when 5101
          {
            "id" => 5101,
            "ref" => "Sample#5101",
            "status" => "To do",
            "labels" => ["repo:ui-app", "trigger:auto-implement"],
            "parent_ref" => "Sample#5100"
          }
        else
          raise "unexpected task id: #{task_id}"
        end
      end

      def fetch_task_by_ref(task_ref)
        raise "unexpected task ref fetch: #{task_ref}"
      end

      def load_task_labels(task_id)
        case Integer(task_id)
        when 5100
          [{ "title" => "repo:both" }, { "title" => "trigger:auto-parent" }]
        when 5101
          [{ "title" => "repo:ui-app" }, { "title" => "trigger:auto-implement" }]
        else
          []
        end
      end
    end.new

    source = described_class.new(
      client: client,
      project: "Sample",
      repo_label_map: {
        "repo:ui-app" => [:repo_beta],
        "repo:both" => %i[repo_alpha repo_beta]
      },
      trigger_labels: ["trigger:auto-implement", "trigger:auto-parent"]
    )

    tasks = source.load
    parent = tasks.find { |task| task.ref == "Sample#5100" }
    child = tasks.find { |task| task.ref == "Sample#5101" }

    expect(parent.kind).to eq(:parent)
    expect(parent.child_refs).to eq(["Sample#5101"])
    expect(child.parent_ref).to eq("Sample#5100")
  end

  it "does not keep a child ref when relation payload omits status but fetched child is resolved" do
    client = Class.new do
      def run_json_command(*args)
        command = args.fetch(0)
        case command
        when "task-snapshot-list"
          [
            {
              "id" => 5200,
              "ref" => "Sample#5200",
              "status" => "To do",
              "labels" => ["repo:both", "trigger:auto-parent"],
              "parent_ref" => nil
            }
          ]
        when "task-relation-list"
          task_id = Integer(args[args.index("--task-id") + 1])
          case task_id
          when 5200
            {
              "parenttask" => [],
              "subtask" => [
                {
                  "id" => 5201,
                  "ref" => "Sample#5201"
                }
              ]
            }
          when 5201
            {
              "parenttask" => [
                {
                  "id" => 5200,
                  "ref" => "Sample#5200"
                }
              ],
              "subtask" => []
            }
          else
            raise "unexpected relation task id: #{task_id}"
          end
        else
          raise "unexpected command: #{args.inspect}"
        end
      end

      def fetch_task_by_id(task_id)
        case Integer(task_id)
        when 5200
          {
            "id" => 5200,
            "ref" => "Sample#5200",
            "status" => "To do",
            "labels" => ["repo:both", "trigger:auto-parent"]
          }
        when 5201
          {
            "id" => 5201,
            "ref" => "Sample#5201",
            "status" => "Resolved",
            "labels" => ["repo:ui-app", "trigger:auto-implement"],
            "parent_ref" => "Sample#5200"
          }
        else
          raise "unexpected task id: #{task_id}"
        end
      end

      def fetch_task_by_ref(task_ref)
        raise "unexpected task ref fetch: #{task_ref}"
      end

      def load_task_labels(task_id)
        case Integer(task_id)
        when 5200
          [{ "title" => "repo:both" }, { "title" => "trigger:auto-parent" }]
        when 5201
          [{ "title" => "repo:ui-app" }, { "title" => "trigger:auto-implement" }]
        else
          []
        end
      end
    end.new

    source = described_class.new(
      client: client,
      project: "Sample",
      repo_label_map: {
        "repo:ui-app" => [:repo_beta],
        "repo:both" => %i[repo_alpha repo_beta]
      },
      trigger_labels: ["trigger:auto-implement", "trigger:auto-parent"]
    )

    tasks = source.load
    parent = tasks.find { |task| task.ref == "Sample#5200" }

    expect(tasks.map(&:ref)).to eq(["Sample#5200"])
    expect(parent.kind).to eq(:single)
    expect(parent.child_refs).to eq([])
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
      expect(parent.automation_enabled).to eq(true)
      expect(child.automation_enabled).to eq(false)
    end
  end

  it "enables automation for topology-imported related tasks when they match trigger labels" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 5400,
          "ref" => "Sample#5400",
          "status" => "To do",
          "labels" => ["repo:both", "trigger:auto-parent"],
          "parent_ref" => nil
        },
        {
          "id" => 5401,
          "ref" => "Sample#5401",
          "status" => "Inspection",
          "labels" => ["repo:ui-app", "trigger:auto-implement"],
          "parent_ref" => "Sample#5400"
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
      parent = tasks.find { |task| task.ref == "Sample#5400" }
      child = tasks.find { |task| task.ref == "Sample#5401" }

      expect(tasks.map(&:ref)).to eq(["Sample#5400", "Sample#5401"])
      expect(parent.automation_enabled).to eq(true)
      expect(child.status).to eq(:verifying)
      expect(child.automation_enabled).to eq(true)
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
          "labels" => ["repo:ui-app", "trigger:auto-scheduler-validation"],
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
      trigger_labels: ["trigger:auto-scheduler-validation"],
      status: "To do",
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      task = source.fetch_by_external_task_id(5001)

      expect(task.ref).to eq("Sample#5001")
      expect(task.status).to eq(:in_review)
      expect(task.edit_scope).to eq([:repo_beta])
      expect(task.child_refs).to eq([])
      expect(task.external_task_id).to eq(5001)
    end
  end

  it "can fetch a single task by ref without applying the status filter" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 5002,
          "ref" => "Sample#5002",
          "status" => "In review",
          "labels" => ["repo:ui-app", "trigger:auto-scheduler-validation"],
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
      trigger_labels: ["trigger:auto-scheduler-validation"],
      status: "To do",
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      task = source.fetch_by_ref("Sample#5002")

      expect(task.ref).to eq("Sample#5002")
      expect(task.status).to eq(:in_review)
      expect(task.edit_scope).to eq([:repo_beta])
      expect(task.external_task_id).to eq(5002)
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
          "labels" => ["repo:ui-app", "trigger:auto-scheduler-validation", "blocked"],
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
      trigger_labels: ["trigger:auto-scheduler-validation"],
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
          "labels" => ["repo:ui-app", "trigger:auto-scheduler-validation", "blocked"],
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
      trigger_labels: ["trigger:auto-scheduler-validation"],
      status: "To do",
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      expect(source.load).to eq([])
    end
  end

  it "imports kanban blocking relations so the scheduler can respect unresolved blockers" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 5500,
          "ref" => "Sample#5500",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-scheduler-validation"],
          "parent_ref" => nil
        },
        {
          "id" => 5501,
          "ref" => "Sample#5501",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-scheduler-validation"],
          "parent_ref" => nil,
          "blocking_task_refs" => ["Sample#5500"]
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:ui-app" => [:repo_beta]
      },
      trigger_labels: ["trigger:auto-scheduler-validation"],
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      tasks = source.load

      expect(tasks.find { |task| task.ref == "Sample#5501" }.blocking_task_refs).to eq(["Sample#5500"])
    end
  end

  it "keeps blocker refs even when the blocker task is outside A2O repo-label management" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 5600,
          "ref" => "Sample#5600",
          "status" => "To do",
          "labels" => [],
          "parent_ref" => nil
        },
        {
          "id" => 5601,
          "ref" => "Sample#5601",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-scheduler-validation"],
          "parent_ref" => nil,
          "blocking_task_refs" => ["Sample#5600"]
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:ui-app" => [:repo_beta]
      },
      trigger_labels: ["trigger:auto-scheduler-validation"],
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      tasks = source.load

      expect(tasks.map(&:ref)).to eq(["Sample#5601"])
      expect(tasks.fetch(0).blocking_task_refs).to eq(["Sample#5600"])
    end
  end

  it "drops blocker refs once a non-A2O blocker is already Done" do
    fake_cli = create_fake_kanban_cli(
      @tmp_dir,
      snapshots: [
        {
          "id" => 5700,
          "ref" => "Sample#5700",
          "status" => "Done",
          "labels" => [],
          "parent_ref" => nil
        },
        {
          "id" => 5701,
          "ref" => "Sample#5701",
          "status" => "To do",
          "labels" => ["repo:ui-app", "trigger:auto-scheduler-validation"],
          "parent_ref" => nil,
          "blocking_task_refs" => ["Sample#5700"]
        }
      ]
    )

    source = described_class.new(
      command_argv: ["ruby", fake_cli.fetch(:script_path)],
      project: "Sample",
      repo_label_map: {
        "repo:ui-app" => [:repo_beta]
      },
      trigger_labels: ["trigger:auto-scheduler-validation"],
      working_dir: @tmp_dir
    )

    with_env(fake_cli.fetch(:env)) do
      tasks = source.load

      expect(tasks.map(&:ref)).to eq(["Sample#5701"])
      expect(tasks.fetch(0).blocking_task_refs).to eq([])
    end
  end
end
