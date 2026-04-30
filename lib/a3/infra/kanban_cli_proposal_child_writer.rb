# frozen_string_literal: true

module A3
  module Infra
    class KanbanCliProposalChildWriter
      DRAFT_LABEL = "a2o:draft-child"
      DECOMPOSED_LABEL = "a2o:decomposed"
      RUNNABLE_LABEL = "trigger:auto-implement"
      Result = Struct.new(:success?, :parent_ref, :child_refs, :child_keys, :summary, :diagnostics, keyword_init: true)
      class PartialChildWriteError < StandardError
        attr_reader :child_ref, :child_key, :original_error

        def initialize(child_ref:, child_key:, original_error:)
          @child_ref = child_ref
          @child_key = child_key
          @original_error = original_error
          super(original_error.message)
        end
      end

      def initialize(command_argv: nil, project:, working_dir: nil, client: nil, mode: :runnable)
        @project = project.to_s
        @client = client || KanbanCommandClient.subprocess(command_argv: command_argv, project: @project, working_dir: working_dir)
        @mode = mode.to_sym
        raise A3::Domain::ConfigurationError, "unknown proposal child writer mode: #{mode}" unless %i[runnable draft].include?(@mode)
      end

      def call(parent_task_ref:, parent_external_task_id:, proposal_evidence:)
        proposal = proposal_evidence.fetch("proposal")
        proposal_fingerprint = proposal_evidence.fetch("proposal_fingerprint")
        children = proposal.fetch("children")
        child_refs_by_key = {}
        refs = []
        keys = []
        failed_write = nil
        generated_parent = ensure_generated_parent(
          source_task_ref: parent_task_ref,
          source_external_task_id: parent_external_task_id,
          proposal_fingerprint: proposal_fingerprint
        )
        children.each do |child|
          begin
            ensured = ensure_child(
              parent_task_ref: generated_parent.fetch("ref"),
              parent_external_task_id: generated_parent.fetch("id"),
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
        begin
          reconcile_dependencies(parent_task_ref: generated_parent.fetch("ref"), children: children, child_refs_by_key: child_refs_by_key)
          ensure_source_decomposed(parent_external_task_id) if draft_mode? && parent_external_task_id
        rescue StandardError => e
          failed_write = dependency_failed_write(e)
          raise
        end
        Result.new(success?: true, parent_ref: generated_parent.fetch("ref"), child_refs: refs, child_keys: keys)
      rescue StandardError => e
        Result.new(
          success?: false,
          parent_ref: defined?(generated_parent) && generated_parent ? generated_parent["ref"] : nil,
          child_refs: defined?(refs) ? refs : [],
          child_keys: defined?(keys) ? keys : [],
          summary: "decomposition child creation failed",
          diagnostics: { "error" => e.message, "failed_write" => failed_write }
        )
      end

      private

      def ensure_generated_parent(source_task_ref:, source_external_task_id:, proposal_fingerprint:)
        payload = generated_parent_payload(source_task_ref: source_task_ref, proposal_fingerprint: proposal_fingerprint)
        task = find_existing_generated_parent(source_task_ref) || create_child(payload)
        ensure_label(task.fetch("id"), DECOMPOSED_LABEL)
        ensure_relation(source_external_task_id, task.fetch("id"), relation_kind: "related") if source_external_task_id
        ensure_comment(task.fetch("id"), payload.fetch("comment"))
        ensure_source_parent_comment(source_external_task_id, generated_parent_ref: task.fetch("ref"), proposal_fingerprint: proposal_fingerprint) if source_external_task_id
        task
      end

      def generated_parent_payload(source_task_ref:, proposal_fingerprint:)
        {
          "title" => "Implementation plan for #{source_task_ref}",
          "description" => <<~DESC.strip,
            Decomposition source: #{source_task_ref}
            Proposal fingerprint: #{proposal_fingerprint}

            This generated parent groups implementation draft children created from the requirement ticket.
          DESC
          "priority" => 2,
          "comment" => "Created generated implementation parent for requirement #{source_task_ref}; proposal #{proposal_fingerprint}."
        }
      end

      def find_existing_generated_parent(source_task_ref)
        matches = @client.run_json_command("task-find", "--project", @project, "--query", source_task_ref)
        exact = hydrate_task_find_matches(matches).select { |task| task.fetch("description", "").include?("Decomposition source: #{source_task_ref}") }
        if exact.size > 1
          duplicates = exact.map { |task| "#{task["ref"] || "unknown-ref"}(id=#{task["id"] || "unknown"})" }.join(", ")
          raise A3::Domain::ConfigurationError, "duplicate generated decomposition parents for #{source_task_ref}: #{duplicates}"
        end

        exact.first
      end

      def ensure_child(parent_task_ref:, parent_external_task_id:, proposal_fingerprint:, child:)
        child_key = child.fetch("child_key")
        payload = canonical_task_payload(parent_task_ref: parent_task_ref, proposal_fingerprint: proposal_fingerprint, child: child)
        existing = find_existing_child(child_key)
        task = existing || create_child(payload)
        labels_for(child, created: !existing).each { |label| ensure_label(task.fetch("id"), label) }
        ensure_relation(parent_external_task_id, task.fetch("id"), relation_kind: "subtask") if parent_external_task_id
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
        comment = if draft_mode?
                    "Created draft from decomposition proposal #{proposal_fingerprint}; child key #{child_key}. Add #{RUNNABLE_LABEL} to accept for implementation."
                  else
                    "Created from decomposition proposal #{proposal_fingerprint}; child key #{child_key}."
                  end
        if draft_mode? && proposal_labels(child).include?(RUNNABLE_LABEL)
          comment = "#{comment} Proposal suggested #{RUNNABLE_LABEL}, but draft mode did not apply it."
        end
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
          "comment" => comment
        }
      end

      def labels_for(child, created:)
        labels = proposal_labels(child)
        if draft_mode?
          return [DRAFT_LABEL] unless created

          ([DRAFT_LABEL] + labels.reject { |label| trigger_label?(label) }).uniq
        else
          ([RUNNABLE_LABEL] + labels).uniq
        end
      end

      def trigger_label?(label)
        label.to_s.start_with?("trigger:")
      end

      def proposal_labels(child)
        Array(child["labels"]).map(&:to_s).reject(&:empty?)
      end

      def draft_mode?
        @mode == :draft
      end

      def reconcile_dependencies(parent_task_ref:, children:, child_refs_by_key:)
        children.each do |child|
          Array(child["depends_on"]).each do |dependency_key|
            dependency_ref = child_refs_by_key[dependency_key]
            child_ref = child_refs_by_key[child.fetch("child_key")]
            next unless dependency_ref && child_ref

            begin
              dependency = @client.fetch_task_by_ref(dependency_ref)
              dependent = @client.fetch_task_by_ref(child_ref)
              ensure_blocker_relation(dependency.fetch("id"), dependent.fetch("id"))
              ensure_comment(dependent.fetch("id"), "Blocked by decomposition dependency #{dependency_ref} from #{parent_task_ref}.")
            rescue StandardError => e
              raise DependencyWriteError.new(child_key: child.fetch("child_key"), dependency_key: dependency_key, child_ref: child_ref, dependency_ref: dependency_ref, original_error: e)
            end
          end
        end
      end

      class DependencyWriteError < StandardError
        attr_reader :child_key, :dependency_key, :child_ref, :dependency_ref, :original_error

        def initialize(child_key:, dependency_key:, child_ref:, dependency_ref:, original_error:)
          @child_key = child_key
          @dependency_key = dependency_key
          @child_ref = child_ref
          @dependency_ref = dependency_ref
          @original_error = original_error
          super(original_error.message)
        end
      end

      def dependency_failed_write(error)
        return nil unless error.is_a?(DependencyWriteError)

        {
          "type" => "dependency",
          "child_key" => error.child_key,
          "dependency_key" => error.dependency_key,
          "child_ref" => error.child_ref,
          "dependency_ref" => error.dependency_ref,
          "error" => error.message
        }
      end

      def find_existing_child(child_key)
        matches = @client.run_json_command("task-find", "--project", @project, "--query", child_key)
        exact = hydrate_task_find_matches(matches).select { |task| task.fetch("description", "").include?("Child key: #{child_key}") }
        if exact.size > 1
          duplicates = exact.map { |task| "#{task["ref"] || "unknown-ref"}(id=#{task["id"] || "unknown"})" }.join(", ")
          raise A3::Domain::ConfigurationError, "duplicate decomposition children for child key #{child_key}: #{duplicates}"
        end

        exact.first
      end

      def hydrate_task_find_matches(matches)
        Array(matches).map do |task|
          next task if task.fetch("description", "").to_s.strip != ""

          ref = task["ref"] || task["task_ref"] || task["reference"]
          ref ? @client.fetch_task_by_ref(ref) : task
        rescue StandardError
          task
        end
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

      def ensure_source_decomposed(parent_task_id)
        ensure_label(parent_task_id, DECOMPOSED_LABEL)
      end

      def ensure_relation(parent_task_id, child_task_id, relation_kind:)
        relations = @client.run_json_command("task-relation-list", "--project", @project, "--task-id", parent_task_id.to_s)
        return if relation_exists?(relations, related_task_id: child_task_id, relation_kind: relation_kind)

        @client.run_command(
          "task-relation-create",
          "--project", @project,
          "--task-id", parent_task_id.to_s,
          "--other-task-id", child_task_id.to_s,
          "--relation-kind", relation_kind
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
          "--relation-kind", "blocked"
        )
      end

      def ensure_comment(task_id, body)
        return if comment_exists?(task_id, body)

        @client.run_command_with_text_file_option(
          "task-comment-create",
          "--project", @project,
          "--task-id", task_id.to_s,
          option_name: "--comment",
          text: body,
          tempfile_prefix: "a2o-decomposition-child-comment"
        )
      end

      def comment_exists?(task_id, body)
        comments = @client.run_json_command("task-comment-list", "--project", @project, "--task-id", task_id.to_s)
        Array(comments).any? do |comment|
          text = comment["bodyMarkdown"] || comment["body"] || comment["comment"] || comment["text"]
          text.to_s == body.to_s
        end
      rescue StandardError
        false
      end

      def ensure_source_parent_comment(source_task_id, generated_parent_ref:, proposal_fingerprint:)
        ensure_comment(
          source_task_id,
          "Generated implementation parent #{generated_parent_ref} from decomposition proposal #{proposal_fingerprint}."
        )
      end

      def relation_exists?(relations, related_task_id:, relation_kind:)
        case relations
        when Hash
          Array(relations[relation_kind]).any? { |relation| Integer(relation["id"]) == Integer(related_task_id) }
        when Array
          relations.any? do |relation|
            (relation["relation_kind"] == relation_kind || relation["kind"] == relation_kind) &&
              Integer(relation["related_task_id"]) == Integer(related_task_id)
          end
        else
          false
        end
      rescue ArgumentError, TypeError
        false
      end

      def blocker_relation_exists?(relations, blocker_task_id:)
        case relations
        when Hash
          (Array(relations["blocked"]) + Array(relations["blocked_by"])).any? do |relation|
            Integer(relation["id"]) == Integer(blocker_task_id)
          end
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
