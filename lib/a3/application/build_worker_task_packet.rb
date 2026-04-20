# frozen_string_literal: true

require_relative "../domain/task_phase_projection"

module A3
  module Application
    class BuildWorkerTaskPacket
      def initialize(external_task_source:)
        @external_task_source = external_task_source
      end

      def call(task:)
        snapshot = external_snapshot_for(task)
        A3::Domain::WorkerTaskPacket.new(
          ref: task.ref,
          external_task_id: task.external_task_id,
          kind: task.kind,
          edit_scope: task.edit_scope,
          verification_scope: task.verification_scope,
          parent_ref: task.parent_ref,
          child_refs: task.child_refs,
          title: snapshot.fetch("title"),
          description: snapshot.fetch("description"),
          status: snapshot.fetch("status"),
          labels: snapshot.fetch("labels")
        )
      end

      private

      def external_snapshot_for(task)
        snapshot =
          if task.external_task_id
            load_by_external_task_id(task)
          else
            load_by_task_ref(task)
          end
        snapshot = synthesized_snapshot(task) if snapshot.nil? && @external_task_source.is_a?(A3::Infra::NullExternalTaskSource)
        raise A3::Domain::ConfigurationError, "missing external task packet for #{task.ref}" unless snapshot.is_a?(Hash)

        snapshot_ref = String(snapshot["ref"]).strip
        if !snapshot_ref.empty? && snapshot_ref != task.ref
          raise A3::Domain::ConfigurationError, "external task packet ref mismatch for #{task.ref}: #{snapshot_ref}"
        end

        title = String(snapshot["title"]).strip
        raise A3::Domain::ConfigurationError, "external task packet title is blank for #{task.ref}" if title.empty?
        description = String(snapshot["description"]).strip
        if description.empty?
          raise A3::Domain::ConfigurationError,
                "kanban task #{task.ref} description is blank; fill in the ticket body/description before running A2O"
        end

        {
          "title" => title,
          "description" => description,
          "status" => canonical_status_label(task, snapshot["status"]),
          "labels" => Array(snapshot["labels"]).map(&:to_s)
        }
      end

      def synthesized_snapshot(task)
        {
          "title" => task.ref,
          "description" => "A3 synthesized task packet because no external task source is configured. Use repository context and task topology as the source of truth.",
          "status" => synthesized_status(task),
          "labels" => []
        }
      end

      def synthesized_status(task)
        {
          todo: "To do",
          in_progress: "In progress",
          in_review: "In review",
          verifying: "Inspection",
          merging: "Merging",
          done: "Done",
          blocked: "Blocked"
        }.fetch(canonical_status_symbol(task, task.status), task.status.to_s)
      end

      def canonical_status_label(task, status)
        {
          todo: "To do",
          in_progress: "In progress",
          in_review: "In review",
          verifying: "Inspection",
          merging: "Merging",
          done: "Done",
          blocked: "Blocked"
        }.fetch(canonical_status_symbol(task, status), status.to_s)
      end

      def canonical_status_symbol(task, status)
        normalized_status =
          case String(status).strip
          when "To do" then :todo
          when "In progress" then :in_progress
          when "In review" then :in_review
          when "Inspection" then :verifying
          when "Merging" then :merging
          when "Done" then :done
          when "Blocked" then :blocked
          else
            status
          end

        A3::Domain::TaskPhaseProjection.status_for(task_kind: task.kind, status: normalized_status)
      end

      def load_by_external_task_id(task)
        unless @external_task_source.respond_to?(:fetch_task_packet_by_external_task_id)
          raise A3::Domain::ConfigurationError, "external task source cannot load task packets for #{task.ref}"
        end

        @external_task_source.fetch_task_packet_by_external_task_id(task.external_task_id)
      end

      def load_by_task_ref(task)
        unless @external_task_source.respond_to?(:fetch_task_packet_by_ref)
          raise A3::Domain::ConfigurationError, "external task source cannot load task packets for #{task.ref}"
        end

        @external_task_source.fetch_task_packet_by_ref(task.ref)
      end
    end
  end
end
