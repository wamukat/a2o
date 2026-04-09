# frozen_string_literal: true

module A3
  module Infra
    class KanbanCliTaskSource
      ACTIVE_STATUS_MAP = {
        "To do" => :todo,
        "In progress" => :in_progress,
        "In review" => :in_review,
        "Inspection" => :verifying,
        "Merging" => :merging,
        "Done" => :done
      }.freeze

      def initialize(command_argv:, project:, repo_label_map:, trigger_labels:, blocked_label: "blocked", status: nil, working_dir: nil)
        @project = project.to_s
        @client = KanbanCliCommandClient.new(command_argv: command_argv, project: @project, working_dir: working_dir)
        @repo_label_map = normalize_repo_label_map(repo_label_map)
        @trigger_labels = Array(trigger_labels).map(&:to_s).reject(&:empty?).freeze
        @blocked_label = blocked_label.to_s
        @status = normalize_status_filter(status)
      end

      def load
        selection_snapshots = load_selection_snapshots
        topology_snapshots = load_topology_snapshots
        build_tasks(selection_snapshots, topology_snapshots: topology_snapshots)
      end

      def fetch_by_external_task_id(task_id)
        payload = @client.fetch_task_by_id(task_id)
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

      def load_selection_snapshots
        args = ["task-snapshot-list", "--project", @project]
        args += ["--status", @status] if pass_status_filter_to_kanban?
        payload = @client.run_json_command(*args)
        raise A3::Domain::ConfigurationError, "kanban task-snapshot-list must return an array" unless payload.is_a?(Array)

        payload.map { |raw_snapshot| normalize_snapshot(raw_snapshot) }.compact.freeze
      end

      def load_topology_snapshots
        payload = @client.run_json_command("task-snapshot-list", "--project", @project)
        raise A3::Domain::ConfigurationError, "kanban task-snapshot-list must return an array" unless payload.is_a?(Array)

        payload.map { |raw_snapshot| normalize_snapshot(raw_snapshot, ignore_status_filter: true, ignore_trigger_filter: true) }.compact.freeze
      end

      def build_tasks(snapshots, topology_snapshots:)
        relevant_snapshots = select_relevant_snapshots(selection_snapshots: snapshots, topology_snapshots: topology_snapshots)
        child_refs_by_parent = build_child_refs_by_parent(relevant_snapshots)
        relevant_snapshots.map { |snapshot| build_task_from_snapshot(snapshot, child_refs_by_parent: child_refs_by_parent) }.freeze
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
        end

        topology_snapshots.select { |snapshot| selected_refs.include?(snapshot.fetch("ref")) }.freeze
      end

      def build_child_refs_by_parent(snapshots)
        snapshots.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |snapshot, refs|
          next unless snapshot.fetch("parent_ref")

          refs[snapshot.fetch("parent_ref")] << snapshot.fetch("ref")
        end
      end

      def build_task_from_snapshot(snapshot, child_refs_by_parent:)
        child_refs = child_refs_by_parent.fetch(snapshot.fetch("ref"), []).sort.freeze
        A3::Domain::Task.new(
          ref: snapshot.fetch("ref"),
          kind: task_kind_for(snapshot: snapshot, child_refs: child_refs),
          edit_scope: snapshot.fetch("edit_scope"),
          verification_scope: snapshot.fetch("edit_scope"),
          status: snapshot.fetch("status"),
          parent_ref: snapshot.fetch("parent_ref"),
          child_refs: child_refs,
          external_task_id: snapshot.fetch("task_id")
        )
      end

      def build_scalar_task_from_snapshot(snapshot)
        A3::Domain::Task.new(
          ref: snapshot.fetch("ref"),
          kind: task_kind_for(snapshot: snapshot, child_refs: [].freeze),
          edit_scope: snapshot.fetch("edit_scope"),
          verification_scope: snapshot.fetch("edit_scope"),
          status: snapshot.fetch("status"),
          parent_ref: snapshot.fetch("parent_ref"),
          child_refs: [],
          external_task_id: snapshot.fetch("task_id")
        )
      end

      def task_kind_for(snapshot:, child_refs:)
        return :parent unless child_refs.empty?
        return :child if snapshot.fetch("parent_ref")

        :single
      end

      def normalize_snapshot(raw_snapshot, ignore_status_filter: false, ignore_trigger_filter: false)
        raise A3::Domain::ConfigurationError, "kanban task snapshot must be an object" unless raw_snapshot.is_a?(Hash)

        labels = Array(raw_snapshot["labels"]).map(&:to_s).reject(&:empty?).freeze
        return nil unless ignore_trigger_filter || @trigger_labels.empty? || (labels & @trigger_labels).any?

        edit_scope = labels.flat_map { |label| @repo_label_map.fetch(label, []) }.uniq.freeze
        return nil if edit_scope.empty?

        status = normalize_status(raw_snapshot.fetch("status", nil), labels: labels)
        return nil unless status
        return nil if @status && !ignore_status_filter && !status_matches_filter?(raw_status: raw_snapshot.fetch("status", nil), normalized_status: status)

        {
          "task_id" => Integer(raw_snapshot.fetch("id")),
          "ref" => String(raw_snapshot.fetch("ref")).strip,
          "status" => status,
          "edit_scope" => edit_scope,
          "parent_ref" => normalize_parent_ref(raw_snapshot["parent_ref"])
        }
      end

      def normalize_status(raw_status, labels:)
        return :blocked if labels.include?(@blocked_label)

        ACTIVE_STATUS_MAP[String(raw_status)]
      end

      def normalize_parent_ref(value)
        normalized = String(value).strip
        normalized.empty? ? nil : normalized
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

        @status == String(raw_status) || @status == display_status_for(normalized_status)
      end

      def display_status_for(status)
        return "Blocked" if status == :blocked

        ACTIVE_STATUS_MAP.invert.fetch(status, status.to_s)
      end

      def load_task_labels(task_id)
        @client.load_task_labels(task_id).map { |item| String(item.fetch("title")) }.reject(&:empty?).freeze
      end
    end
  end
end
