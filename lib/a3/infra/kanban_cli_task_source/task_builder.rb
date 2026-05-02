# frozen_string_literal: true

require "set"

module A3
  module Infra
    class KanbanCliTaskSource
      private

      def build_tasks(snapshots, topology_snapshots:, child_refs_by_parent:)
        trigger_selected_refs = snapshots.map { |snapshot| snapshot.fetch("ref") }.to_set
        relevant_snapshots = select_relevant_snapshots(selection_snapshots: snapshots, topology_snapshots: topology_snapshots)
        relevant_snapshots.map do |snapshot|
          build_task_from_snapshot(
            snapshot,
            child_refs_by_parent: child_refs_by_parent,
            automation_enabled: trigger_selected_refs.include?(snapshot.fetch("ref")) || snapshot.fetch("automation_enabled", false)
          )
        end.freeze
      end

      def select_relevant_snapshots(selection_snapshots:, topology_snapshots:)
        return [].freeze if selection_snapshots.empty?

        snapshots_by_ref = topology_snapshots.each_with_object({}) do |snapshot, memo|
          memo[snapshot.fetch("ref")] = snapshot
        end
        child_refs_by_parent = build_child_refs_by_parent(topology_snapshots)
        selected_refs = selection_snapshots.map { |snapshot| snapshot.fetch("ref") }.to_set
        queue = selected_refs.to_a

        until queue.empty?
          ref = queue.shift
          snapshot = snapshots_by_ref[ref]
          next unless snapshot

          parent_ref = snapshot.fetch("parent_ref")
          if parent_ref && !selected_refs.include?(parent_ref)
            selected_refs << parent_ref
            queue << parent_ref
          end

          child_refs_by_parent.fetch(ref, []).each do |child_ref|
            next if selected_refs.include?(child_ref)

            selected_refs << child_ref
            queue << child_ref
          end

          snapshot.fetch("blocking_task_refs", []).each do |blocker_ref|
            next if selected_refs.include?(blocker_ref)

            selected_refs << blocker_ref
            queue << blocker_ref
          end
        end

        topology_snapshots.select { |snapshot| selected_refs.include?(snapshot.fetch("ref")) }.freeze
      end

      def build_task_from_snapshot(snapshot, child_refs_by_parent:, automation_enabled:)
        child_refs = child_refs_by_parent.fetch(snapshot.fetch("ref"), []).sort.freeze
        task_kind = task_kind_for(snapshot: snapshot, child_refs: child_refs)
        A3::Domain::Task.new(
          ref: snapshot.fetch("ref"),
          kind: task_kind,
          edit_scope: snapshot.fetch("edit_scope"),
          verification_scope: snapshot.fetch("edit_scope"),
          status: canonicalize_status_for_kind(snapshot.fetch("status"), task_kind),
          parent_ref: snapshot.fetch("parent_ref"),
          child_refs: child_refs,
          blocking_task_refs: snapshot.fetch("blocking_task_refs", []),
          priority: snapshot.fetch("priority", 0),
          external_task_id: snapshot.fetch("task_id"),
          automation_enabled: automation_enabled,
          labels: snapshot.fetch("labels", [])
        )
      end

      def build_scalar_task_from_snapshot(snapshot)
        task_kind = task_kind_for(snapshot: snapshot, child_refs: [].freeze)
        A3::Domain::Task.new(
          ref: snapshot.fetch("ref"),
          kind: task_kind,
          edit_scope: snapshot.fetch("edit_scope"),
          verification_scope: snapshot.fetch("edit_scope"),
          status: canonicalize_status_for_kind(snapshot.fetch("status"), task_kind),
          parent_ref: snapshot.fetch("parent_ref"),
          child_refs: [],
          blocking_task_refs: snapshot.fetch("blocking_task_refs", []),
          priority: snapshot.fetch("priority", 0),
          external_task_id: snapshot.fetch("task_id"),
          automation_enabled: true,
          labels: snapshot.fetch("labels", [])
        )
      end

      def task_kind_for(snapshot:, child_refs:)
        return :parent unless child_refs.empty?
        return :child if snapshot.fetch("parent_ref")

        :single
      end

      def canonicalize_status_for_kind(status, task_kind)
        status
      end
    end
  end
end
