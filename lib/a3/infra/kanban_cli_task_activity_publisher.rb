# frozen_string_literal: true

require "tempfile"

module A3
  module Infra
    class KanbanCliTaskActivityPublisher
      attr_reader :command_argv, :project, :working_dir

      def initialize(command_argv:, project:, working_dir: nil)
        @command_argv = Array(command_argv).map(&:to_s).freeze
        @project = project.to_s
        @working_dir = working_dir && File.expand_path(working_dir)
        @client = KanbanCliCommandClient.new(command_argv: @command_argv, project: @project, working_dir: @working_dir)
      end

      def publish(task_ref:, body:, external_task_id: nil)
        task_id = resolve_task_id(task_ref, external_task_id: external_task_id)
        raise A3::Domain::ConfigurationError, "kanban task ref must be canonical Project#N: #{task_ref}" unless task_id

        run_comment_command(task_id: task_id, body: body)
      end

      private

      def resolve_task_id(task_ref, external_task_id:)
        @client.resolve_task_id(task_ref, external_task_id: external_task_id, canonical_required: false)
      end

      def run_command(*args)
        @client.run_command(*args)
      end

      def run_comment_command(task_id:, body:)
        Tempfile.create(["a3-comment", ".md"], @working_dir || Dir.tmpdir) do |file|
          file.write(String(body))
          file.flush
          run_command(
            "task-comment-create",
            "--project", @project,
            "--task-id", task_id.to_s,
            "--comment-file", file.path
          )
        end
      end

    end
  end
end
