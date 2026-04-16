# frozen_string_literal: true

module A3
  module Infra
    class KanbanCliTaskActivityPublisher
      attr_reader :command_argv, :project, :working_dir

      def initialize(command_argv: nil, project:, working_dir: nil, client: nil)
        @command_argv = Array(command_argv).map(&:to_s).freeze
        @project = project.to_s
        @working_dir = working_dir && File.expand_path(working_dir)
        @client = client || KanbanCommandClient.subprocess(command_argv: @command_argv, project: @project, working_dir: @working_dir)
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

      def run_comment_command(task_id:, body:)
        @client.run_command_with_text_file_option(
          "task-comment-create",
          "--project", @project,
          "--task-id", task_id.to_s,
          option_name: "--comment",
          text: body,
          tempfile_prefix: "a3-comment"
        )
      end

    end
  end
end
