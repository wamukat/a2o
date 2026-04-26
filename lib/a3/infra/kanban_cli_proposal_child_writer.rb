# frozen_string_literal: true

module A3
  module Infra
    class KanbanCliProposalChildWriter
      Result = Struct.new(:success?, :child_refs, :child_keys, :summary, :diagnostics, keyword_init: true)
      class PartialChildWriteError < StandardError
        attr_reader :child_ref, :child_key, :original_error

        def initialize(child_ref:, child_key:, original_error:)
          @child_ref = child_ref
          @child_key = child_key
          @original_error = original_error
          super(original_error.message)
        end
      end

      def initialize(command_argv: nil, project:, working_dir: nil, client: nil)
        @project = project.to_s
        @client = client || KanbanCommandClient.subprocess(command_argv: command_argv, project: @project, working_dir: working_dir)
      end

      def call(parent_task_ref:, parent_external_task_id:, proposal_evidence:)
        proposal = proposal_evidence.fetch("proposal")
        proposal_fingerprint = proposal_evidence.fetch("proposal_fingerprint")
        children = proposal.fetch("children")
        child_refs_by_key = {}
        refs = []
        keys = []
        failed_write = nil
        children.each do |child|
          begin
            ensured = ensure_child(
              parent_task_ref: parent_task_ref,
              parent_external_task_id: parent_external_task_id,
              proposal_fingerprint: proposal_fingerprint,
              child: child
            )
            child_refs_by_key[ensured.fetch("child_key")] = ensured.fetch("ref")
            refs << ensured.fetch("ref")
            keys << ensured.fetch("child_key")
          rescue StandardError => e
            if e.is_a?(PartialChildWriteError)
              refs << e.child_ref if e.child_ref
              keys << e.child_key if e.child_key
            end
            failed_write = { "child_key" => child["child_key"], "error" => e.message }
            raise
          end
        end
        reconcile_dependencies(parent_task_ref: parent_task_ref, children: children, child_refs_by_key: child_refs_by_key)
        Result.new(success?: true, child_refs: refs, child_keys: keys)
      rescue StandardError => e
        Result.new(
          success?: false,
          child_refs: defined?(refs) ? refs : [],
          child_keys: defined?(keys) ? keys : [],
          summary: "decomposition child creation failed",
          diagnostics: { "error" => e.message, "failed_write" => failed_write }
        )
      end

      private

      def ensure_child(parent_task_ref:, parent_external_task_id:, proposal_fingerprint:, child:)
        child_key = child.fetch("child_key")
        payload = canonical_task_payload(parent_task_ref: parent_task_ref, proposal_fingerprint: proposal_fingerprint, child: child)
        existing = find_existing_child(child_key)
        task = existing || create_child(payload)
        ensure_label(task.fetch("id"), "trigger:auto-implement")
        Array(child["labels"]).each { |label| ensure_label(task.fetch("id"), label) }
        ensure_relation(parent_external_task_id, task.fetch("id")) if parent_external_task_id
        ensure_comment(task.fetch("id"), payload.fetch("comment"))
        { "ref" => task.fetch("ref"), "child_key" => child_key, "id" => task.fetch("id") }
      rescue StandardError => e
        if task
          raise PartialChildWriteError.new(child_ref: task["ref"], child_key: child_key, original_error: e)
        end

        raise
      end

      def canonical_task_payload(parent_task_ref:, proposal_fingerprint:, child:)
        child_key = child.fetch("child_key")
        {
          "title" => child.fetch("title"),
          "description" => <<~DESC.strip,
            Parent: #{parent_task_ref}
            Proposal fingerprint: #{proposal_fingerprint}
            Child key: #{child_key}

            #{child.fetch("body")}

            Acceptance:
            #{Array(child["acceptance_criteria"]).map { |item| "- #{item}" }.join("\n")}

            Rationale:
            #{child.fetch("rationale")}
          DESC
          "priority" => child["priority"] || 2,
          "comment" => "Created from decomposition proposal #{proposal_fingerprint}; child key #{child_key}."
        }
      end

      def reconcile_dependencies(parent_task_ref:, children:, child_refs_by_key:)
        children.each do |child|
          Array(child["depends_on"]).each do |dependency_key|
            dependency_ref = child_refs_by_key[dependency_key]
            child_ref = child_refs_by_key[child.fetch("child_key")]
            next unless dependency_ref && child_ref

            dependency = @client.fetch_task_by_ref(dependency_ref)
            dependent = @client.fetch_task_by_ref(child_ref)
            ensure_blocker_relation(dependency.fetch("id"), dependent.fetch("id"))
            ensure_comment(dependent.fetch("id"), "Blocked by decomposition dependency #{dependency_ref} from #{parent_task_ref}.")
          end
        end
      end

      def find_existing_child(child_key)
        matches = @client.run_json_command("task-find", "--project", @project, "--query", child_key)
        exact = Array(matches).select { |task| task.fetch("description", "").include?("Child key: #{child_key}") }
        raise A3::Domain::ConfigurationError, "duplicate decomposition children for child key #{child_key}" if exact.size > 1

        exact.first
      end

      def create_child(payload)
        @client.run_json_command_with_text_file_option(
          "task-create",
          "--project", @project,
          "--title", payload.fetch("title"),
          "--status", "To do",
          "--priority", payload.fetch("priority").to_s,
          option_name: "--description",
          text: payload.fetch("description"),
          tempfile_prefix: "a2o-decomposition-child-description"
        )
      end

      def ensure_label(task_id, label)
        return if label.to_s.empty?

        @client.run_command("label-ensure", "--project", @project, "--title", label.to_s)
        @client.run_command("task-label-add", "--project", @project, "--task-id", task_id.to_s, "--label", label.to_s)
      end

      def ensure_relation(parent_task_id, child_task_id)
        relations = @client.run_json_command("task-relation-list", "--project", @project, "--task-id", parent_task_id.to_s)
        return if child_relation_exists?(relations, child_task_id: child_task_id)

        @client.run_command(
          "task-relation-create",
          "--project", @project,
          "--task-id", parent_task_id.to_s,
          "--other-task-id", child_task_id.to_s,
          "--relation-kind", "subtask"
        )
      end

      def ensure_blocker_relation(blocker_task_id, blocked_task_id)
        relations = @client.run_json_command("task-relation-list", "--project", @project, "--task-id", blocked_task_id.to_s)
        return if blocker_relation_exists?(relations, blocker_task_id: blocker_task_id)

        @client.run_command(
          "task-relation-create",
          "--project", @project,
          "--task-id", blocked_task_id.to_s,
          "--other-task-id", blocker_task_id.to_s,
          "--relation-kind", "blocked_by"
        )
      end

      def ensure_comment(task_id, body)
        @client.run_command_with_text_file_option(
          "task-comment-create",
          "--project", @project,
          "--task-id", task_id.to_s,
          option_name: "--comment",
          text: body,
          tempfile_prefix: "a2o-decomposition-child-comment"
        )
      end

      def child_relation_exists?(relations, child_task_id:)
        case relations
        when Hash
          Array(relations["subtask"]).any? { |relation| Integer(relation["id"]) == Integer(child_task_id) }
        when Array
          relations.any? { |relation| Integer(relation["related_task_id"]) == Integer(child_task_id) }
        else
          false
        end
      rescue ArgumentError, TypeError
        false
      end

      def blocker_relation_exists?(relations, blocker_task_id:)
        case relations
        when Hash
          Array(relations["blocked_by"]).any? { |relation| Integer(relation["id"]) == Integer(blocker_task_id) }
        when Array
          relations.any? { |relation| Integer(relation["related_task_id"]) == Integer(blocker_task_id) }
        else
          false
        end
      rescue ArgumentError, TypeError
        false
      end
    end
  end
end
