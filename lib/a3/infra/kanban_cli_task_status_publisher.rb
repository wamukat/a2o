# frozen_string_literal: true

module A3
  module Infra
    class KanbanCliTaskStatusPublisher
      STATUS_MAP = {
        blocked: "To do",
        in_progress: "In progress",
        in_review: "In review",
        verifying: "Inspection",
        merging: "Merging",
        done: "Done"
      }.freeze

      def initialize(command_argv:, project:, blocked_label: "blocked", working_dir: nil)
        @project = project.to_s
        @client = KanbanCliCommandClient.new(command_argv: command_argv, project: @project, working_dir: working_dir)
        @blocked_label = blocked_label.to_s
      end

      def publish(task_ref:, status:, external_task_id: nil)
        task_id = resolve_task_id(task_ref, external_task_id: external_task_id)
        normalized_status = status.to_sym

        if normalized_status == :blocked
          add_blocked_label(task_id)
          target_status = STATUS_MAP.fetch(:blocked)
          run_command("task-transition", "--project", @project, "--task-id", task_id.to_s, "--status", target_status)
          return nil
        end

        remove_blocked_label(task_id)

        target_status = STATUS_MAP[normalized_status]
        return nil unless target_status

        run_command("task-transition", "--project", @project, "--task-id", task_id.to_s, "--status", target_status)
      end

      private

      def resolve_task_id(task_ref, external_task_id:)
        @client.resolve_task_id(task_ref, external_task_id: external_task_id, canonical_required: true)
      end

      def canonical_task_ref(task_ref)
        value = task_ref.to_s.strip
        return value if /\A.+?#\d+\z/.match?(value)

        nil
      end

      def run_command(*args)
        @client.run_command(*args)
      end

      def add_blocked_label(task_id)
        run_command("task-label-add", "--project", @project, "--task-id", task_id.to_s, "--label", @blocked_label)
      end

      def remove_blocked_label(task_id)
        return nil unless blocked_label_present?(task_id)

        run_command("task-label-remove", "--project", @project, "--task-id", task_id.to_s, "--label", @blocked_label)
      end

      def blocked_label_present?(task_id)
        payload = @client.load_task_labels(task_id, include_project: true)
        payload.any? { |item| String(item.fetch("title", "")).strip == @blocked_label }
      end
    end
  end
end
