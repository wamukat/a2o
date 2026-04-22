# frozen_string_literal: true

module FakeKanbanCliHelper
  def create_fake_kanban_cli(base_dir, snapshots:, mutate_state_on_transition: false, task_get_includes_labels: true)
    state_path = File.join(base_dir, "kanban-snapshots.json")
    transitions_path = File.join(base_dir, "kanban-transitions.jsonl")
    comments_path = File.join(base_dir, "kanban-comments.json")
    script_path = File.join(base_dir, "fake-kanban-cli.rb")

    File.write(state_path, JSON.pretty_generate(snapshots))
    File.write(comments_path, JSON.pretty_generate({}))
    File.write(
      script_path,
      <<~RUBY
        #!/usr/bin/env ruby
        # frozen_string_literal: true

        require "json"
        require "fileutils"

        state_path = ENV.fetch("FAKE_KANBAN_STATE_PATH")
        transitions_path = ENV.fetch("FAKE_KANBAN_TRANSITIONS_PATH")
        comments_path = ENV.fetch("FAKE_KANBAN_COMMENTS_PATH")
        mutate_state_on_transition = ENV.fetch("FAKE_KANBAN_MUTATE_STATE_ON_TRANSITION", "0") == "1"
        task_get_includes_labels = ENV.fetch("FAKE_KANBAN_TASK_GET_INCLUDES_LABELS", "1") == "1"
        command = ARGV.fetch(0)

        case command
        when "task-snapshot-list"
          status = ARGV.each_cons(2).find { |flag, _value| flag == "--status" }&.last
          include_closed = ARGV.include?("--include-closed")
          snapshots = JSON.parse(File.read(state_path))
          unless include_closed
            snapshots.select! do |item|
              current_status = String(item["status"])
              !["Resolved", "Archived"].include?(current_status)
            end
          end
          snapshots.select! { |item| item["status"] == status } if status
          print JSON.generate(snapshots)
        when "task-watch-summary-list"
          task_refs = []
          task_ids = []
          ignore_missing = ARGV.include?("--ignore-missing")
          ARGV.each_cons(2) do |flag, value|
            task_refs << value if flag == "--task"
            task_ids << Integer(value) if flag == "--task-id"
          end
          snapshots = JSON.parse(File.read(state_path))
          selected = []
          task_ids.each do |task_id|
            task = snapshots.find { |item| Integer(item["id"]) == task_id }
            if task.nil?
              next if ignore_missing
              warn("task not found: \#{task_id}")
              exit 1
            end
            selected << task
          end
          task_refs.each do |task_ref|
            task = snapshots.find { |item| item["ref"] == task_ref }
            if task.nil?
              next if ignore_missing
              warn("task not found: \#{task_ref}")
              exit 1
            end
            selected << task
          end
          rendered = selected.uniq { |item| Integer(item["id"]) }.sort_by { |item| item["ref"] }.map do |item|
            {
              "id" => Integer(item["id"]),
              "ref" => item["ref"],
              "title" => item["title"] || "",
              "status" => item["status"]
            }
          end
          print JSON.generate(rendered)
        when "task-get"
          task_ref = ARGV.each_cons(2).find { |flag, _value| flag == "--task" }&.last
          task_id = ARGV.each_cons(2).find { |flag, _value| flag == "--task-id" }&.last
          snapshots = JSON.parse(File.read(state_path))
          task = snapshots.find do |item|
            item["ref"] == task_ref || (!task_id.nil? && Integer(item["id"]) == Integer(task_id))
          end
          if task.nil?
            warn("task not found: \#{task_ref || task_id}")
            exit 1
          end
          task = task.dup
          task.delete("labels") unless task_get_includes_labels
          print JSON.generate(task)
        when "task-label-list"
          task_id = ARGV.each_cons(2).find { |flag, _value| flag == "--task-id" }&.last
          snapshots = JSON.parse(File.read(state_path))
          task = snapshots.find { |item| !task_id.nil? && Integer(item["id"]) == Integer(task_id) }
          if task.nil?
            warn("task not found: \#{task_id}")
            exit 1
          end
          labels = Array(task["labels"]).map do |label|
            {
              "id" => 0,
              "title" => label,
              "description" => "",
              "hex_color" => ""
            }
          end
          print JSON.generate(labels)
        when "task-relation-list"
          task_id = ARGV.each_cons(2).find { |flag, _value| flag == "--task-id" }&.last
          snapshots = JSON.parse(File.read(state_path))
          task = snapshots.find { |item| !task_id.nil? && Integer(item["id"]) == Integer(task_id) }
          if task.nil?
            warn("task not found: \#{task_id}")
            exit 1
          end
          task_ref = task["ref"]
          parent = snapshots.find { |item| item["ref"] == task["parent_ref"] }
          children = snapshots.select { |item| item["parent_ref"] == task_ref }
          render_relation = lambda do |item|
            {
              "id" => Integer(item["id"]),
              "ref" => item["ref"],
              "title" => item["title"] || "",
              "status" => item["status"],
              "project_id" => 1,
              "project_title" => item["ref"].split("#", 2).first
            }
          end
          blockers = snapshots.select { |item| Array(task["blocking_task_refs"]).include?(item["ref"]) }
          print JSON.generate(
            {
              "parenttask" => parent ? [render_relation.call(parent)] : [],
              "subtask" => children.map { |item| render_relation.call(item) },
              "blocked" => blockers.map { |item| render_relation.call(item) },
              "blocking" => [],
              "related" => [],
              "duplicateof" => [],
              "duplicates" => []
            }
          )
        when "task-transition"
          task_id = ARGV.each_cons(2).find { |flag, _value| flag == "--task-id" }&.last
          target_status = ARGV.each_cons(2).find { |flag, _value| flag == "--status" }&.last
          FileUtils.mkdir_p(File.dirname(transitions_path))
          File.open(transitions_path, "a") do |file|
            file.puts(JSON.generate({"argv" => ARGV}))
          end
          if mutate_state_on_transition && task_id && target_status
            snapshots = JSON.parse(File.read(state_path))
            task = snapshots.find { |item| Integer(item["id"]) == Integer(task_id) }
            if task
              task["status"] = target_status
              File.write(state_path, JSON.pretty_generate(snapshots))
            end
          end
          print JSON.generate({"ok" => true})
        when "task-label-add", "task-label-remove"
          task_id = ARGV.each_cons(2).find { |flag, _value| flag == "--task-id" }&.last
          label = ARGV.each_cons(2).find { |flag, _value| flag == "--label" || flag == "--title" }&.last
          FileUtils.mkdir_p(File.dirname(transitions_path))
          File.open(transitions_path, "a") do |file|
            file.puts(JSON.generate({"argv" => ARGV}))
          end
          snapshots = JSON.parse(File.read(state_path))
          task = snapshots.find { |item| !task_id.nil? && Integer(item["id"]) == Integer(task_id) }
          if task.nil?
            warn("task not found: \#{task_id}")
            exit 1
          end
          labels = Array(task["labels"]).map(&:to_s)
          if command == "task-label-add"
            labels << String(label) unless labels.include?(String(label))
          else
            labels.delete(String(label))
          end
          task["labels"] = labels
          File.write(state_path, JSON.pretty_generate(snapshots))
          rendered = labels.map do |entry|
            {
              "id" => 0,
              "title" => entry,
              "description" => "",
              "hex_color" => ""
            }
          end
          print JSON.generate(rendered)
        when "task-comment-list"
          task_id = ARGV.each_cons(2).find { |flag, _value| flag == "--task-id" }&.last
          comments_by_task = JSON.parse(File.read(comments_path))
          print JSON.generate(comments_by_task.fetch(String(task_id), []))
        when "task-comment-create"
          task_id = ARGV.each_cons(2).find { |flag, _value| flag == "--task-id" }&.last
          comment = ARGV.each_cons(2).find { |flag, _value| flag == "--comment" }&.last
          comment_file = ARGV.each_cons(2).find { |flag, _value| flag == "--comment-file" }&.last
          comment = File.read(comment_file) if comment.nil? && comment_file
          comments_by_task = JSON.parse(File.read(comments_path))
          task_comments = comments_by_task.fetch(String(task_id), [])
          next_id = (task_comments.map { |item| Integer(item["id"]) }.max || 0) + 1
          created = {
            "id" => next_id,
            "comment" => String(comment),
            "date_creation" => next_id,
            "date_modification" => next_id,
            "user_id" => 1,
            "username" => "a3-v2",
            "name" => "A3-v2"
          }
          task_comments << created
          comments_by_task[String(task_id)] = task_comments
          File.write(comments_path, JSON.pretty_generate(comments_by_task))
          print JSON.generate(created)
        else
          warn("unsupported command: \#{command}")
          exit 1
        end
      RUBY
    )
    FileUtils.chmod("+x", script_path)

    {
      script_path: script_path,
      state_path: state_path,
      transitions_path: transitions_path,
      comments_path: comments_path,
      env: {
        "FAKE_KANBAN_STATE_PATH" => state_path,
        "FAKE_KANBAN_TRANSITIONS_PATH" => transitions_path,
        "FAKE_KANBAN_COMMENTS_PATH" => comments_path,
        "FAKE_KANBAN_MUTATE_STATE_ON_TRANSITION" => (mutate_state_on_transition ? "1" : "0"),
        "FAKE_KANBAN_TASK_GET_INCLUDES_LABELS" => (task_get_includes_labels ? "1" : "0")
      }
    }
  end

  def read_fake_kanban_transitions(path)
    return [] unless File.exist?(path)

    File.readlines(path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
  end

  def read_fake_kanban_comments(path)
    return {} unless File.exist?(path)

    JSON.parse(File.read(path))
  end
end
