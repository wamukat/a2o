# frozen_string_literal: true

module A3
  module Infra
    class KanbanCliFollowUpChildWriter
      Result = Struct.new(:success?, :child_refs, :child_fingerprints, :summary, :diagnostics, keyword_init: true)

      FOLLOW_UP_LABEL = "a3-v2:follow-up-child"

      def initialize(command_argv:, project:, working_dir: nil)
        @project = project.to_s
        @client = KanbanCliCommandClient.new(command_argv: command_argv, project: @project, working_dir: working_dir)
      end

      def call(parent_task_ref:, parent_external_task_id:, review_run_ref:, disposition:)
        repo_scopes_for(disposition.repo_scope).each_with_object({ refs: [], fingerprints: [] }) do |repo_scope, acc|
          child = ensure_child(
            parent_task_ref: parent_task_ref,
            parent_external_task_id: parent_external_task_id,
            review_run_ref: review_run_ref,
            disposition: disposition,
            repo_scope: repo_scope
          )
          acc[:refs] << child.fetch("ref")
          acc[:fingerprints] << child.fetch("fingerprint")
        end.then do |result|
          Result.new(success?: true, child_refs: result.fetch(:refs), child_fingerprints: result.fetch(:fingerprints))
        end
      rescue StandardError => e
        Result.new(success?: false, child_refs: [], child_fingerprints: [], summary: "follow-up child creation failed", diagnostics: { "error" => e.message })
      end

      private

      def repo_scopes_for(repo_scope)
        return %i[repo_alpha repo_beta] if repo_scope.to_sym == :both

        [repo_scope.to_sym]
      end

      def ensure_child(parent_task_ref:, parent_external_task_id:, review_run_ref:, disposition:, repo_scope:)
        fingerprint = fingerprint_for(
          parent_task_ref: parent_task_ref,
          review_run_ref: review_run_ref,
          repo_scope: repo_scope,
          finding_key: disposition.finding_key
        )
        existing = find_existing_child(fingerprint)
        task_payload = canonical_task_payload(parent_task_ref: parent_task_ref, disposition: disposition, repo_scope: repo_scope, fingerprint: fingerprint)
        child = existing || create_child(task_payload)
        ensure_canonical_payload!(child, canonical: task_payload, parent_external_task_id: parent_external_task_id) if existing
        ensure_label(child.fetch("id"), task_payload.fetch("repo_label"))
        ensure_label(child.fetch("id"), "trigger:auto-implement")
        ensure_label(child.fetch("id"), FOLLOW_UP_LABEL)
        ensure_relation(parent_external_task_id, child.fetch("id"))
        { "ref" => child.fetch("ref"), "fingerprint" => fingerprint, "id" => child.fetch("id") }
      end

      def fingerprint_for(parent_task_ref:, review_run_ref:, repo_scope:, finding_key:)
        [parent_task_ref, review_run_ref, repo_scope, finding_key].join("|")
      end

      def find_existing_child(fingerprint)
        matches = @client.run_json_command("task-find", "--project", @project, "--query", fingerprint)
        return nil unless matches.is_a?(Array)

        exact = matches.select do |task|
          task.fetch("description", "").include?(fingerprint) || task.fetch("title", "").include?(fingerprint)
        end
        raise A3::Domain::ConfigurationError, "duplicate follow-up children for fingerprint #{fingerprint}" if exact.size > 1

        exact.first
      end

      def canonical_task_payload(parent_task_ref:, disposition:, repo_scope:, fingerprint:)
        repo_label = repo_scope == :repo_alpha ? "repo:starters" : "repo:ui-app"
        {
          "title" => "Follow-up for #{parent_task_ref} (#{repo_scope}): #{disposition.summary}",
          "description" => <<~DESC.strip,
            Parent: #{parent_task_ref}
            Repo scope: #{repo_scope}
            Fingerprint: #{fingerprint}

            Summary:
            #{disposition.summary}

            Details:
            #{disposition.description}
          DESC
          "repo_label" => repo_label
        }
      end

      def create_child(task_payload)
        @client.run_json_command(
          "task-create",
          "--project", @project,
          "--title", task_payload.fetch("title"),
          "--description", task_payload.fetch("description"),
          "--status", "To do"
        )
      end

      def ensure_canonical_payload!(task, canonical:, parent_external_task_id:)
        actual_title = task.fetch("title")
        actual_description = task.fetch("description", "")
        labels = Array(@client.load_task_labels(task.fetch("id"), include_project: true)).map { |item| item["title"] }.sort
        expected_labels = [canonical.fetch("repo_label"), "trigger:auto-implement", FOLLOW_UP_LABEL]
        expected_labels.sort!
        relation_exists = Array(
          @client.run_json_command("task-relation-list", "--project", @project, "--task-id", parent_external_task_id.to_s)
        ).any? do |relation|
          relation["task_id"] == parent_external_task_id && relation["related_task_id"] == task.fetch("id")
        end
        return if actual_title == canonical.fetch("title") &&
                  actual_description == canonical.fetch("description") &&
                  labels == expected_labels &&
                  relation_exists

        raise A3::Domain::ConfigurationError, "follow-up child payload mismatch for #{task.fetch('ref')}"
      end

      def ensure_label(task_id, label)
        @client.run_command("label-ensure", "--project", @project, "--title", label)
        @client.run_command("task-label-add", "--project", @project, "--task-id", task_id.to_s, "--label", label)
      end

      def ensure_relation(parent_task_id, child_task_id)
        relations = @client.run_json_command("task-relation-list", "--project", @project, "--task-id", parent_task_id.to_s)
        return if Array(relations).any? { |relation| relation["task_id"] == parent_task_id && relation["related_task_id"] == child_task_id }

        @client.run_command(
          "task-relation-create",
          "--project", @project,
          "--task-id", parent_task_id.to_s,
          "--other-task-id", child_task_id.to_s,
          "--relation-kind", "subtask"
        )
      end

    end
  end
end
