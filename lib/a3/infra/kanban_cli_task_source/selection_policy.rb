# frozen_string_literal: true

module A3
  module Infra
    class KanbanCliTaskSource
      private

      def normalize_snapshot(raw_snapshot, ignore_status_filter: false, ignore_trigger_filter: false, include_decomposition_sources: false)
        raise A3::Domain::ConfigurationError, "kanban task snapshot must be an object" unless raw_snapshot.is_a?(Hash)

        labels = Array(raw_snapshot["labels"]).map(&:to_s).reject(&:empty?).freeze
        task_ref = String(raw_snapshot.fetch("ref")).strip
        return nil unless ignore_trigger_filter || @trigger_labels.empty? || (labels & @trigger_labels).any?
        return nil if task_closed?(raw_snapshot.fetch("status", nil), raw_snapshot["done"], raw_snapshot["is_archived"])
        return nil if !include_decomposition_sources && decomposed_source_selected_only_for_decomposition?(labels)

        status = normalize_status(raw_snapshot.fetch("status", nil), labels: labels)
        return nil unless status
        ignore_status_for_decomposition_source =
          include_decomposition_sources && labels.include?(A3::Domain::Task::DECOMPOSITION_TRIGGER_LABEL)
        if @status && !ignore_status_filter && !ignore_status_for_decomposition_source &&
            !status_matches_filter?(raw_status: raw_snapshot.fetch("status", nil), normalized_status: status)
          return nil
        end

        edit_scope = resolve_edit_scope(labels: labels, task_ref: task_ref)

        {
          "task_id" => Integer(raw_snapshot.fetch("id")),
          "ref" => task_ref,
          "status" => status,
          "edit_scope" => edit_scope,
          "labels" => labels,
          "parent_ref" => normalize_parent_ref(raw_snapshot["parent_ref"]),
          "blocking_task_refs" => normalize_blocking_refs(raw_snapshot["blocking_task_refs"]),
          "priority" => normalize_priority(raw_snapshot["priority"]),
          "automation_enabled" => trigger_selected?(labels)
        }
      end

      def trigger_selected?(labels)
        @trigger_labels.empty? || !(labels & @trigger_labels).empty?
      end

      def decomposed_source_selected_only_for_decomposition?(labels)
        return false unless labels.include?(A3::Domain::Task::DECOMPOSED_LABEL)
        return false unless @trigger_labels.include?(A3::Domain::Task::DECOMPOSITION_TRIGGER_LABEL)

        ((labels & @trigger_labels) - [A3::Domain::Task::DECOMPOSITION_TRIGGER_LABEL]).empty?
      end

      def resolve_edit_scope(labels:, task_ref:)
        edit_scope = labels.flat_map { |label| @repo_label_map.fetch(label, []) }.uniq.freeze
        return edit_scope unless edit_scope.empty?
        return [] if unscoped_decomposition_source?(labels)
        return configured_edit_scope_universe if unscoped_parent_automation?(labels)

        configured_labels = @repo_label_map.keys.sort
        label_summary = labels.empty? ? "(none)" : labels.sort.join(", ")
        configured_summary = configured_labels.empty? ? "(none)" : configured_labels.join(", ")
        raise A3::Domain::ConfigurationError,
              "kanban task #{task_ref} has no repo label that maps to an A2O edit scope; " \
              "task labels=#{label_summary}; configured repo labels=#{configured_summary}; " \
              "add one or more configured repo labels to the kanban task"
      end

      def unscoped_decomposition_source?(labels)
        labels.include?(A3::Domain::Task::DECOMPOSITION_TRIGGER_LABEL)
      end

      def unscoped_parent_automation?(labels)
        return false unless labels.include?("trigger:auto-parent")
        return false unless @trigger_labels.include?("trigger:auto-parent")
        return false if labels.any? { |label| label.start_with?("repo:") }

        ((labels & @trigger_labels) - ["trigger:auto-parent"]).empty?
      end

      def configured_edit_scope_universe
        @repo_label_map.values.flatten.uniq.freeze
      end

      def resolve_topology_edit_scope(labels)
        edit_scope = labels.flat_map { |label| @repo_label_map.fetch(label, []) }.uniq.freeze
        edit_scope.empty? ? nil : edit_scope
      end

      def normalize_status(raw_status, labels:)
        return :blocked if labels.include?(@blocked_label)
        return :needs_clarification if labels.include?(@clarification_label)

        ACTIVE_STATUS_MAP[String(raw_status)]
      end

      def closed_status?(raw_status)
        %w[Resolved Archived].include?(String(raw_status))
      end

      def task_resolved?(raw_status, raw_done)
        closed_status?(raw_status) || raw_done == true
      end

      def task_closed?(raw_status, raw_done, raw_archived)
        task_resolved?(raw_status, raw_done) || raw_archived == true
      end

      def blocking_status_resolved?(raw_status)
        closed_status?(raw_status) || String(raw_status) == "Done"
      end

      def normalize_parent_ref(value)
        normalized = String(value).strip
        normalized.empty? ? nil : normalized
      end

      def normalize_blocking_refs(values)
        Array(values).map { |value| String(value).strip }.reject(&:empty?).uniq.freeze
      end

      def normalize_priority(value)
        Integer(value || 0)
      rescue ArgumentError, TypeError
        0
      end

      def normalize_repo_label_map(repo_label_map)
        repo_label_map.each_with_object({}) do |(label, scopes), normalized|
          normalized[label.to_s] = Array(scopes).map(&:to_sym).uniq.freeze
        end.freeze
      end

      def normalize_status_filter(status)
        value = String(status).strip
        value.empty? ? nil : value
      end

      def pass_status_filter_to_kanban?
        return false unless @status

        ACTIVE_STATUS_MAP.key?(String(@status))
      end

      def status_matches_filter?(raw_status:, normalized_status:)
        return @status == display_status_for(normalized_status) if normalized_status == :blocked
        return @status == display_status_for(normalized_status) if normalized_status == :needs_clarification

        @status == String(raw_status) || @status == display_status_for(normalized_status)
      end

      def display_status_for(status)
        return "Blocked" if status == :blocked
        return "Needs clarification" if status == :needs_clarification

        ACTIVE_STATUS_MAP.invert.fetch(status, status.to_s)
      end
    end
  end
end
