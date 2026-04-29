# frozen_string_literal: true

module A3
  module Infra
    class KanbanCliDraftAcceptanceWriter
      DRAFT_LABEL = "a2o:draft-child"
      READY_LABEL = "a2o:ready-child"
      RUNNABLE_LABEL = "trigger:auto-implement"
      PARENT_RUNNABLE_LABEL = "trigger:auto-parent"

      Result = Struct.new(:success?, :accepted_refs, :skipped_refs, :parent_automation_applied, :summary, :diagnostics, keyword_init: true)

      def initialize(command_argv: nil, project:, working_dir: nil, client: nil)
        @project = project.to_s
        @client = client || KanbanCommandClient.subprocess(command_argv: command_argv, project: @project, working_dir: working_dir)
      end

      def call(parent_task_ref:, parent_external_task_id:, child_refs: [], all: false, ready_only: false, remove_draft_label: false, parent_auto: false)
        parent = parent_task(parent_task_ref: parent_task_ref, parent_external_task_id: parent_external_task_id)
        related_refs = related_child_refs(parent.fetch("id"))
        selected_refs, unrelated_explicit_refs = selected_child_refs(related_refs: related_refs, child_refs: child_refs, all: all, ready_only: ready_only)
        accepted = []
        skipped = unrelated_explicit_refs
        selected_refs.each do |child_ref|
          child = @client.fetch_task_by_ref(child_ref)
          labels = label_names(@client.load_task_labels(child.fetch("id")))
          unless labels.include?(DRAFT_LABEL)
            skipped << child_ref
            next
          end
          if ready_only && !labels.include?(READY_LABEL)
            skipped << child_ref
            next
          end

          changed = ensure_child_accepted(child: child, labels: labels, remove_draft_label: remove_draft_label)
          ensure_child_comment(child.fetch("id"), parent_task_ref: parent_task_ref) if changed
          accepted << child_ref
        end

        parent_changed = false
        if parent_auto && accepted.any?
          parent_labels = label_names(@client.load_task_labels(parent.fetch("id")))
          parent_changed = ensure_label(parent.fetch("id"), PARENT_RUNNABLE_LABEL, existing_labels: parent_labels)
          ensure_parent_comment(parent.fetch("id"), accepted_refs: accepted) if parent_changed
        end

        Result.new(
          success?: true,
          accepted_refs: accepted.freeze,
          skipped_refs: skipped.freeze,
          parent_automation_applied: parent_changed,
          summary: "accepted #{accepted.size} draft child ticket(s); skipped #{skipped.size}"
        )
      rescue StandardError => e
        Result.new(
          success?: false,
          accepted_refs: defined?(accepted) ? accepted : [],
          skipped_refs: defined?(skipped) ? skipped : [],
          parent_automation_applied: false,
          summary: "draft child acceptance failed",
          diagnostics: { "error" => e.message }
        )
      end

      private

      def parent_task(parent_task_ref:, parent_external_task_id:)
        return @client.fetch_task_by_id(parent_external_task_id) if parent_external_task_id

        @client.fetch_task_by_ref(parent_task_ref)
      end

      def selected_child_refs(related_refs:, child_refs:, all:, ready_only:)
        explicit_refs = Array(child_refs).map(&:to_s).reject(&:empty?)
        unless explicit_refs.empty?
          selected = explicit_refs & related_refs
          unrelated = explicit_refs - related_refs
          return [selected.uniq.freeze, unrelated.uniq.freeze]
        end

        return [[], []] unless all || ready_only

        [related_refs, []]
      end

      def related_child_refs(parent_id)
        relations = @client.run_json_command("task-relation-list", "--project", @project, "--task-id", parent_id.to_s)
        normalize_subtask_refs(relations).uniq.freeze
      end

      def normalize_subtask_refs(relations)
        case relations
        when Hash
          Array(relations["subtask"]).filter_map { |item| item["ref"] || item["task_ref"] }
        when Array
          relations.select { |item| item["relation_kind"] == "subtask" || item["kind"] == "subtask" }.filter_map { |item| item["ref"] || item["related_task_ref"] }
        else
          []
        end
      end

      def ensure_child_accepted(child:, labels:, remove_draft_label:)
        changed = ensure_label(child.fetch("id"), RUNNABLE_LABEL, existing_labels: labels)
        changed = remove_label(child.fetch("id"), DRAFT_LABEL, existing_labels: labels) || changed if remove_draft_label
        changed
      end

      def ensure_label(task_id, label, existing_labels:)
        return false if existing_labels.include?(label)

        @client.run_command("label-ensure", "--project", @project, "--title", label)
        @client.run_command("task-label-add", "--project", @project, "--task-id", task_id.to_s, "--label", label)
        true
      end

      def remove_label(task_id, label, existing_labels:)
        return false unless existing_labels.include?(label)

        @client.run_command("task-label-remove", "--project", @project, "--task-id", task_id.to_s, "--label", label)
        true
      end

      def ensure_child_comment(task_id, parent_task_ref:)
        @client.run_command_with_text_file_option(
          "task-comment-create",
          "--project", @project,
          "--task-id", task_id.to_s,
          option_name: "--comment",
          text: "Accepted decomposition draft child for #{parent_task_ref}; added #{RUNNABLE_LABEL}.",
          tempfile_prefix: "a2o-accept-draft-child-comment"
        )
      end

      def ensure_parent_comment(task_id, accepted_refs:)
        @client.run_command_with_text_file_option(
          "task-comment-create",
          "--project", @project,
          "--task-id", task_id.to_s,
          option_name: "--comment",
          text: "Accepted decomposition child work: #{accepted_refs.join(', ')}. Added #{PARENT_RUNNABLE_LABEL}.",
          tempfile_prefix: "a2o-accept-draft-parent-comment"
        )
      end

      def label_names(labels)
        Array(labels).map do |label|
          case label
          when Hash
            label["title"] || label["name"] || label.dig("tag", "title") || label.dig("tag", "name")
          else
            label
          end
        end.map(&:to_s).reject(&:empty?).uniq.freeze
      end
    end
  end
end
