# frozen_string_literal: true

require "set"

module A3
  module Infra
    class KanbanCliTaskSource
      private

      def load_topology(selection_snapshots:)
        snapshots_by_ref = selection_snapshots.each_with_object({}) do |snapshot, memo|
          memo[snapshot.fetch("ref")] = snapshot
        end
        child_refs_by_parent = build_child_refs_by_parent(selection_snapshots)
        queued_refs = Set.new
        queue = selection_snapshots.map do |snapshot|
          queued_refs << snapshot.fetch("ref")
          [snapshot.fetch("ref"), snapshot.fetch("task_id")]
        end

        until queue.empty?
          task_ref, task_id = queue.shift
          topology_snapshot, parent_ref, topology_open, related_refs = fetch_topology_snapshot(task_ref: task_ref, task_id: task_id)
          snapshots_by_ref[topology_snapshot.fetch("ref")] = topology_snapshot if topology_snapshot
          child_refs_by_parent[parent_ref] << task_ref if parent_ref && topology_open

          related_refs.each do |related_ref, related_task_id|
            next if snapshots_by_ref.key?(related_ref) || queued_refs.include?(related_ref)

            queued_refs << related_ref
            queue << [related_ref, related_task_id]
          end
        end

        {
          snapshots: snapshots_by_ref.values.freeze,
          child_refs_by_parent: normalize_child_refs_by_parent(child_refs_by_parent)
        }.freeze
      end

      def fetch_topology_snapshot(task_ref:, task_id:)
        payload =
          if task_id
            @client.fetch_task_by_id(task_id)
          else
            @client.fetch_task_by_ref(task_ref)
          end
        resolved_task_id = Integer(payload.fetch("id"))
        labels = load_task_labels(resolved_task_id)
        task_ref = String(payload.fetch("ref")).strip
        relations = @client.run_json_command("task-relation-list", "--project", @project, "--task-id", resolved_task_id.to_s)
        raise A3::Domain::ConfigurationError, "kanban task-relation-list must return an object" unless relations.is_a?(Hash)

        parent_refs = normalize_relation_refs(relations.fetch("parenttask", []))
        child_refs = normalize_relation_refs(relations.fetch("subtask", []))
        blocking_refs = normalize_blocking_relation_refs(relations.fetch("blocked", []))

        resolved = task_closed?(payload.fetch("status", nil), payload["done"], payload["is_archived"])

        [
          normalize_topology_snapshot(
            task_id: resolved_task_id,
            task_ref: task_ref,
            raw_status: payload.fetch("status", nil),
            raw_done: payload["done"],
            raw_archived: payload["is_archived"],
            raw_priority: payload["priority"],
            labels: labels,
            parent_ref: parent_refs.first&.first,
            blocking_task_refs: blocking_refs.map(&:first)
          ),
          parent_refs.first&.first,
          !resolved,
          (parent_refs + child_refs + blocking_refs).to_h
        ]
      end

      def normalize_topology_snapshot(task_id:, task_ref:, raw_status:, raw_done:, raw_archived:, raw_priority:, labels:, parent_ref:, blocking_task_refs:)
        return nil if task_closed?(raw_status, raw_done, raw_archived)

        status = normalize_status(raw_status, labels: labels)
        return nil unless status
        edit_scope = resolve_topology_edit_scope(labels)
        return nil unless edit_scope

        {
          "task_id" => task_id,
          "ref" => task_ref,
          "status" => status,
          "edit_scope" => edit_scope,
          "labels" => labels,
          "parent_ref" => parent_ref,
          "blocking_task_refs" => normalize_blocking_refs(blocking_task_refs),
          "priority" => normalize_priority(raw_priority),
          "automation_enabled" => trigger_selected?(labels)
        }
      end

      def normalize_relation_refs(items)
        Array(items).each_with_object([]) do |item, refs|
          next unless item.is_a?(Hash)

          ref = String(item["ref"]).strip
          task_id = integer_or_nil(item["id"])
          status = String(item["status"]).strip
          next if ref.empty? || task_id.nil?
          next if !status.empty? && closed_status?(status)

          refs << [ref, task_id]
        end
      end

      def normalize_blocking_relation_refs(items)
        Array(items).each_with_object([]) do |item, refs|
          next unless item.is_a?(Hash)

          ref = String(item["ref"]).strip
          task_id = integer_or_nil(item["id"])
          status = String(item["status"]).strip
          next if ref.empty? || task_id.nil?
          next if !status.empty? && blocking_status_resolved?(status)
          next if item["is_archived"] == true || item["isArchived"] == true

          refs << [ref, task_id]
        end
      end

      def build_child_refs_by_parent(snapshots)
        snapshots.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |snapshot, refs|
          next unless snapshot.fetch("parent_ref")

          refs[snapshot.fetch("parent_ref")] << snapshot.fetch("ref")
        end
      end

      def normalize_child_refs_by_parent(child_refs_by_parent)
        child_refs_by_parent.each_with_object({}) do |(parent_ref, refs), normalized|
          normalized[parent_ref] = refs.uniq.sort.freeze
        end.freeze
      end

      def integer_or_nil(value)
        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
