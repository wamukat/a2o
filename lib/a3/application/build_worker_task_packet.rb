# frozen_string_literal: true

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
        raise A3::Domain::ConfigurationError, "missing external task packet for #{task.ref}" unless snapshot.is_a?(Hash)

        snapshot_ref = String(snapshot["ref"]).strip
        if !snapshot_ref.empty? && snapshot_ref != task.ref
          raise A3::Domain::ConfigurationError, "external task packet ref mismatch for #{task.ref}: #{snapshot_ref}"
        end

        title = String(snapshot["title"]).strip
        raise A3::Domain::ConfigurationError, "external task packet title is blank for #{task.ref}" if title.empty?
        description = String(snapshot["description"]).strip
        raise A3::Domain::ConfigurationError, "external task packet description is blank for #{task.ref}" if description.empty?

        {
          "title" => title,
          "description" => description,
          "status" => String(snapshot["status"]),
          "labels" => Array(snapshot["labels"]).map(&:to_s)
        }
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
