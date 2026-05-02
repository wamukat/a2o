# frozen_string_literal: true

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
        selection = load_selection_snapshots(tolerate_invalid_edit_scope: true, include_decomposition_sources: true)
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
          "parent_ref" => normalize_parent_ref(payload["parent_ref"]),
          "remote" => payload["remote"]
        }
      end

      def load_selection_snapshots(tolerate_invalid_edit_scope: false, include_decomposition_sources: false)
        args = ["task-snapshot-list", "--project", @project]
        args += ["--status", @status] if pass_status_filter_to_kanban? && !include_decomposition_sources
        payload = @client.run_json_command(*args)
        raise A3::Domain::ConfigurationError, "kanban task-snapshot-list must return an array" unless payload.is_a?(Array)

        if tolerate_invalid_edit_scope
          snapshots = []
          warnings = []
          payload.each do |raw_snapshot|
            snapshots << normalize_snapshot(raw_snapshot, include_decomposition_sources: include_decomposition_sources)
          rescue A3::Domain::ConfigurationError => e
            warnings << watch_summary_warning(raw_snapshot: raw_snapshot, error: e)
          end

          return {
            snapshots: snapshots.compact.freeze,
            warnings: warnings.freeze
          }.freeze
        end

        payload.map do |raw_snapshot|
          normalize_snapshot(raw_snapshot, include_decomposition_sources: include_decomposition_sources)
        end.compact.freeze
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

      def load_task_labels(task_id)
        @client.load_task_labels(task_id).map { |item| String(item.fetch("title")) }.reject(&:empty?).freeze
      end
    end
  end
end

require "a3/infra/kanban_cli_task_source/topology"
require "a3/infra/kanban_cli_task_source/task_builder"
require "a3/infra/kanban_cli_task_source/selection_policy"
