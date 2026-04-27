# frozen_string_literal: true

require "json"

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

      def publish(task_ref:, body:, external_task_id: nil, event: nil)
        task_id = resolve_task_id(task_ref, external_task_id: external_task_id)
        raise A3::Domain::ConfigurationError, "kanban task ref must be canonical Project#N: #{task_ref}" unless task_id

        if event
          run_event_command(task_id: task_id, body: body, event: event)
        else
          run_comment_command(task_id: task_id, body: body)
        end
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

      def run_event_command(task_id:, body:, event:)
        event_payload = stringify_keys(event)
        args = [
          "task-event-create",
          "--project", @project,
          "--task-id", task_id.to_s,
          "--source", event_payload.fetch("source", "a2o"),
          "--kind", event_payload.fetch("kind"),
          "--title", event_payload.fetch("title"),
          "--summary", event_payload.fetch("summary"),
          "--severity", event_payload.fetch("severity", "info")
        ]
        args += ["--icon", event_payload.fetch("icon")] if present?(event_payload.fetch("icon", nil))
        data = event_payload.fetch("data", nil)
        args += ["--data-json", JSON.generate(data)] if data.is_a?(Hash) && !data.empty?

        @client.run_command_with_text_file_option(
          *args,
          option_name: "--fallback-comment",
          text: body,
          tempfile_prefix: "a3-event-fallback"
        )
      end

      def stringify_keys(hash)
        hash.each_with_object({}) do |(key, value), memo|
          memo[key.to_s] = value.is_a?(Hash) ? stringify_keys(value) : value
        end
      end

      def present?(value)
        !value.nil? && !value.to_s.strip.empty?
      end

    end
  end
end
