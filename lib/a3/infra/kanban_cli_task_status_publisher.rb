# frozen_string_literal: true

require "json"
require_relative "../domain/task_phase_projection"

module A3
  module Infra
    class KanbanCliTaskStatusPublisher
      STATUS_MAP = {
        blocked: "To do",
        needs_clarification: "To do",
        in_progress: "In progress",
        in_review: "In review",
        verifying: "Inspection",
        merging: "Merging",
        done: "Done"
      }.freeze

      def initialize(command_argv: nil, project:, blocked_label: "blocked", clarification_label: "needs:clarification", working_dir: nil, client: nil)
        @project = project.to_s
        @client = client || KanbanCommandClient.subprocess(command_argv: command_argv, project: @project, working_dir: working_dir)
        @blocked_label = blocked_label.to_s
        @clarification_label = clarification_label.to_s
      end

      def publish(task_ref:, status:, external_task_id: nil, task_kind: nil, status_reason: nil, status_details: nil)
        task_id = resolve_task_id(task_ref, external_task_id: external_task_id)
        normalized_status = canonical_status(task_kind: task_kind, status: status)

        if normalized_status == :blocked
          add_blocked_label(task_id, reason: status_reason, details: status_details)
          remove_clarification_label(task_id)
          target_status = STATUS_MAP.fetch(:blocked)
          run_command("task-transition", "--project", @project, "--task-id", task_id.to_s, "--status", target_status)
          return nil
        end

        return nil if blocked_label_present?(task_id)

        if normalized_status == :needs_clarification
          add_clarification_label(task_id, reason: status_reason, details: status_details)
          target_status = STATUS_MAP.fetch(:needs_clarification)
          run_command("task-transition", "--project", @project, "--task-id", task_id.to_s, "--status", target_status)
          return nil
        end

        remove_clarification_label(task_id)

        target_status = STATUS_MAP[normalized_status]
        return nil unless target_status

        run_command("task-transition", "--project", @project, "--task-id", task_id.to_s, "--status", target_status)
      end

      def blocked?(task_ref:, external_task_id: nil)
        task_id = resolve_task_id(task_ref, external_task_id: external_task_id)
        blocked_label_present?(task_id)
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

      def add_blocked_label(task_id, reason:, details:)
        add_reasoned_label(task_id, @blocked_label, reason: reason, details: details)
      end

      def add_clarification_label(task_id, reason:, details:)
        add_reasoned_label(task_id, @clarification_label, reason: reason, details: details)
      end

      def add_reasoned_label(task_id, label, reason:, details:)
        args = ["task-label-add", "--project", @project, "--task-id", task_id.to_s, "--label", label]
        normalized_reason = normalized_optional_text(reason)
        args += ["--reason", normalized_reason] if normalized_reason
        args += ["--details-json", JSON.generate(details)] if details.is_a?(Hash) && !details.empty?
        run_command(*args)
      end

      def remove_blocked_label(task_id)
        return nil unless blocked_label_present?(task_id)

        run_command("task-label-remove", "--project", @project, "--task-id", task_id.to_s, "--label", @blocked_label)
      end

      def remove_clarification_label(task_id)
        return nil unless clarification_label_present?(task_id)

        run_command("task-label-remove", "--project", @project, "--task-id", task_id.to_s, "--label", @clarification_label)
      end

      def blocked_label_present?(task_id)
        label_present?(task_id, @blocked_label)
      end

      def clarification_label_present?(task_id)
        label_present?(task_id, @clarification_label)
      end

      def label_present?(task_id, label)
        payload = @client.load_task_labels(task_id, include_project: true)
        payload.any? { |item| String(item.fetch("title", "")).strip == label }
      end

      def canonical_status(task_kind:, status:)
        return status.to_sym unless task_kind

        A3::Domain::TaskPhaseProjection.status_for(task_kind: task_kind, status: status)
      end

      def normalized_optional_text(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
