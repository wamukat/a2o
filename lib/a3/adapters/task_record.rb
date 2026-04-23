# frozen_string_literal: true

module A3
  module Adapters
    module TaskRecord
      module_function

      def dump(task)
        {
          "ref" => task.ref,
          "kind" => task.kind.to_s,
          "edit_scope" => task.edit_scope.map(&:to_s),
          "verification_scope" => task.verification_scope.map(&:to_s),
          "status" => task.status.to_s,
          "current_run_ref" => task.current_run_ref,
          "parent_ref" => task.parent_ref,
          "child_refs" => task.child_refs,
          "blocking_task_refs" => task.blocking_task_refs,
          "priority" => task.priority,
          "external_task_id" => task.external_task_id,
          "verification_source_ref" => task.verification_source_ref,
          "automation_enabled" => task.automation_enabled
        }
      end

      def load(record)
        A3::Domain::Task.new(
          ref: record.fetch("ref"),
          kind: record.fetch("kind"),
          edit_scope: record.fetch("edit_scope"),
          verification_scope: record.fetch("verification_scope"),
          status: record.fetch("status"),
          current_run_ref: record["current_run_ref"],
          parent_ref: record["parent_ref"],
          child_refs: record.fetch("child_refs", []),
          blocking_task_refs: record.fetch("blocking_task_refs", []),
          priority: record.fetch("priority", 0),
          external_task_id: record["external_task_id"],
          verification_source_ref: record["verification_source_ref"],
          automation_enabled: record.fetch("automation_enabled", true)
        )
      end
    end
  end
end
