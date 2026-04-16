# frozen_string_literal: true

module A3
  module Infra
    class KanbanCliTaskSnapshotReader
      SnapshotIndex = Struct.new(:by_ref, :by_id, keyword_init: true)

      def initialize(command_argv: nil, project:, working_dir: nil, client: nil)
        @project = project.to_s
        @client = client || KanbanCommandClient.subprocess(command_argv: command_argv, project: @project, working_dir: working_dir)
      end

      def load(task_ids: [], task_refs: [])
        payload = @client.run_json_command(*build_command_args(task_ids: task_ids, task_refs: task_refs))
        raise A3::Domain::ConfigurationError, "kanban task-watch-summary-list must return an array" unless payload.is_a?(Array)

        by_ref = {}
        by_id = {}
        payload.each do |item|
          next unless item.is_a?(Hash)

          ref = String(item["ref"]).strip
          by_ref[ref] = item unless ref.empty?

          task_id = integer_or_nil(item["id"])
          by_id[task_id] = item if task_id
        end

        SnapshotIndex.new(by_ref: by_ref.freeze, by_id: by_id.freeze)
      end

      private

      def build_command_args(task_ids:, task_refs:)
        args = ["task-watch-summary-list", "--project", @project, "--ignore-missing"]
        Array(task_ids).compact.each { |task_id| args += ["--task-id", task_id.to_i.to_s] }
        Array(task_refs).compact.map(&:to_s).map(&:strip).reject(&:empty?).each do |task_ref|
          args += ["--task", task_ref]
        end
        args
      end

      def integer_or_nil(value)
        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end

    end
  end
end
