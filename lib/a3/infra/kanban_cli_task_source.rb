# frozen_string_literal: true

require "set"

module A3
  module Infra
    class KanbanCliTaskSource
      WatchSummaryLoadResult = Struct.new(:tasks, :warnings, keyword_init: true)

      ACTIVE_STATUS_MAP = {
        "To do" => :todo,
        "In progress" => :in_progress,
        "In review" => :in_review,
        "Inspection" => :verifying,
        "Merging" => :merging,
        "Done" => :done
      }.freeze

      def initialize(command_argv: nil, project:, repo_label_map:, trigger_labels:, blocked_label: "blocked", clarification_label: "needs:clarification", status: nil, working_dir: nil, client: nil)
        @project = project.to_s
        @client = client || KanbanCommandClient.subprocess(command_argv: command_argv, project: @project, working_dir: working_dir)
        @repo_label_map = normalize_repo_label_map(repo_label_map)
        @trigger_labels = Array(trigger_labels).map(&:to_s).reject(&:empty?).freeze
        @blocked_label = blocked_label.to_s
        @clarification_label = clarification_label.to_s
        @status = normalize_status_filter(status)
      end

      def load
        selection_snapshots = load_selection_snapshots
        topology = load_topology(selection_snapshots: selection_snapshots)
        build_tasks(
          selection_snapshots,
          topology_snapshots: topology.fetch(:snapshots),
          child_refs_by_parent: topology.fetch(:child_refs_by_parent)
        )
      end

      def load_for_watch_summary
        selection = load_selection_snapshots(tolerate_invalid_edit_scope: true)
        selection_snapshots = selection.fetch(:snapshots)
        topology = load_topology(selection_snapshots: selection_snapshots)
        tasks = build_tasks(
          selection_snapshots,
          topology_snapshots: topology.fetch(:snapshots),
          child_refs_by_parent: topology.fetch(:child_refs_by_parent)
        )
        WatchSummaryLoadResult.new(tasks: tasks, warnings: selection.fetch(:warnings))
      end

      def fetch_by_external_task_id(task_id)
        payload = @client.fetch_task_by_id(task_id)
        payload["labels"] = load_task_labels(task_id)
        snapshot = normalize_snapshot(payload, ignore_status_filter: true)
        return nil unless snapshot

        build_scalar_task_from_snapshot(snapshot)
      end

      def fetch_by_ref(task_ref)
        payload = @client.fetch_task_by_ref(task_ref)
        task_id = Integer(payload.fetch("id"))
        payload["labels"] = load_task_labels(task_id)
        snapshot = normalize_snapshot(payload, ignore_status_filter: true)
        return nil unless snapshot

        build_scalar_task_from_snapshot(snapshot)
      end

      def fetch_task_packet_by_external_task_id(task_id)
        payload = @client.fetch_task_by_id(task_id)
        payload["labels"] = load_task_labels(task_id)
        normalize_task_packet(payload)
      end

      def fetch_task_packet_by_ref(task_ref)
        payload = @client.fetch_task_by_ref(task_ref)
        payload["labels"] = load_task_labels(Integer(payload.fetch("id")))
        normalize_task_packet(payload)
      end

      private

      def normalize_task_packet(payload)
        {
          "task_id" => Integer(payload.fetch("id")),
          "ref" => String(payload.fetch("ref")).strip,
          "title" => String(payload["title"]).strip,
          "description" => String(payload["description"]),
          "status" => String(payload["status"]),
          "labels" => Array(payload["labels"]).map(&:to_s).reject(&:empty?).freeze,
          "parent_ref" => normalize_parent_ref(payload["parent_ref"])
        }
      end

      def load_selection_snapshots(tolerate_invalid_edit_scope: false)
        args = ["task-snapshot-list", "--project", @project]
        args += ["--status", @status] if pass_status_filter_to_kanban?
        payload = @client.run_json_command(*args)
        raise A3::Domain::ConfigurationError, "kanban task-snapshot-list must return an array" unless payload.is_a?(Array)

        if tolerate_invalid_edit_scope
          snapshots = []
          warnings = []
          payload.each do |raw_snapshot|
            snapshots << normalize_snapshot(raw_snapshot)
          rescue A3::Domain::ConfigurationError => e
            warnings << watch_summary_warning(raw_snapshot: raw_snapshot, error: e)
          end

          return {
            snapshots: snapshots.compact.freeze,
            warnings: warnings.freeze
          }.freeze
        end

        payload.map { |raw_snapshot| normalize_snapshot(raw_snapshot) }.compact.freeze
      rescue A3::Domain::ConfigurationError => e
        return tolerate_invalid_edit_scope ? { snapshots: [], warnings: [] }.freeze : [] if missing_project_error?(e)

        raise
      end

      def missing_project_error?(error)
        error.message.include?("Project not found: #{@project}")
      end

      def watch_summary_warning(raw_snapshot:, error:)
        ref =
          if raw_snapshot.is_a?(Hash)
            String(raw_snapshot["ref"]).strip
          else
            ""
          end
        prefix = ref.empty? ? "kanban task" : "kanban task #{ref}"
        "#{prefix} skipped: #{error.message}"
      end

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

      def normalize_snapshot(raw_snapshot, ignore_status_filter: false, ignore_trigger_filter: false)
        raise A3::Domain::ConfigurationError, "kanban task snapshot must be an object" unless raw_snapshot.is_a?(Hash)

        labels = Array(raw_snapshot["labels"]).map(&:to_s).reject(&:empty?).freeze
        task_ref = String(raw_snapshot.fetch("ref")).strip
        return nil unless ignore_trigger_filter || @trigger_labels.empty? || (labels & @trigger_labels).any?
        return nil if task_closed?(raw_snapshot.fetch("status", nil), raw_snapshot["done"], raw_snapshot["is_archived"])
        return nil if decomposed_source_selected_only_for_decomposition?(labels)

        edit_scope = resolve_edit_scope(labels: labels, task_ref: task_ref)

        status = normalize_status(raw_snapshot.fetch("status", nil), labels: labels)
        return nil unless status
        return nil if @status && !ignore_status_filter && !status_matches_filter?(raw_status: raw_snapshot.fetch("status", nil), normalized_status: status)

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
        return configured_edit_scope_universe if unscoped_decomposed_parent_automation?(labels)

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

      def unscoped_decomposed_parent_automation?(labels)
        return false unless labels.include?(A3::Domain::Task::DECOMPOSED_LABEL)
        return false unless labels.include?("trigger:auto-parent")
        return false unless @trigger_labels.include?("trigger:auto-parent")

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

      def load_task_labels(task_id)
        @client.load_task_labels(task_id).map { |item| String(item.fetch("title")) }.reject(&:empty?).freeze
      end

      def integer_or_nil(value)
        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
