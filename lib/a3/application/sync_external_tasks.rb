# frozen_string_literal: true

require "set"

module A3
  module Application
    class SyncExternalTasks
      Result = Struct.new(:imported_task_refs, :preserved_active_task_refs, :pruned_task_refs, keyword_init: true)

      def initialize(task_repository:, external_task_source:)
        @task_repository = task_repository
        @external_task_source = external_task_source
      end

      def call
        return empty_result if null_external_task_source?

        imported_tasks = @external_task_source.load
        imported_refs = imported_tasks.map(&:ref).to_set
        preserved_active_task_refs = []

        imported_tasks.each do |task|
          existing_task = fetch_existing_task(task.ref)
          if active_task?(existing_task)
            @task_repository.save(reconcile_active_task(existing_task, task))
            preserved_active_task_refs << task.ref
            next
          end

          @task_repository.save(reconcile_imported_task(existing_task, task))
        end

        pruned_task_refs = prune_non_active_tasks_missing_from(imported_refs)

        Result.new(
          imported_task_refs: imported_tasks.map(&:ref).freeze,
          preserved_active_task_refs: preserved_active_task_refs.freeze,
          pruned_task_refs: pruned_task_refs.freeze
        )
      end

      private

      def empty_result
        Result.new(
          imported_task_refs: [].freeze,
          preserved_active_task_refs: [].freeze,
          pruned_task_refs: [].freeze
        )
      end

      def null_external_task_source?
        @external_task_source.is_a?(A3::Infra::NullExternalTaskSource)
      end

      def prune_non_active_tasks_missing_from(imported_refs)
        @task_repository.all.each_with_object([]) do |task, pruned|
          next if imported_refs.include?(task.ref)
          next if active_task?(task)
          next if terminal_task?(task)

          refreshed_task = refresh_missing_task(task)
          if refreshed_task
            @task_repository.save(refreshed_task)
          else
            @task_repository.delete(task.ref)
            pruned << task.ref
          end
        end
      end

      def refresh_missing_task(task)
        return nil unless task.external_task_id
        return nil unless @external_task_source.respond_to?(:fetch_by_external_task_id)

        refreshed_task = @external_task_source.fetch_by_external_task_id(task.external_task_id)
        return nil unless refreshed_task

        preserve_existing_topology(task, refreshed_task)
      end

      def reconcile_active_task(existing_task, imported_task)
        build_reconciled_task(
          ref: existing_task.ref,
          kind: reconcile_kind(existing_task: existing_task, imported_task: imported_task),
          edit_scope: imported_task.edit_scope,
          verification_scope: imported_task.verification_scope,
          status: existing_task.status,
          current_run_ref: existing_task.current_run_ref,
          parent_ref: reconcile_parent_ref(existing_task: existing_task, imported_task: imported_task),
          child_refs: reconcile_child_refs(existing_task: existing_task, imported_task: imported_task),
          blocking_task_refs: imported_task.blocking_task_refs,
          priority: imported_task.priority,
          external_task_id: imported_task.external_task_id,
          verification_source_ref: existing_task.verification_source_ref,
          automation_enabled: reconcile_automation_enabled(existing_task, imported_task)
        )
      end

      def reconcile_imported_task(existing_task, imported_task)
        automation_enabled = reconcile_automation_enabled(existing_task, imported_task)
        return imported_task if automation_enabled == imported_task.automation_enabled

        build_reconciled_task(
          ref: imported_task.ref,
          kind: imported_task.kind,
          edit_scope: imported_task.edit_scope,
          verification_scope: imported_task.verification_scope,
          status: imported_task.status,
          current_run_ref: imported_task.current_run_ref,
          parent_ref: imported_task.parent_ref,
          child_refs: imported_task.child_refs,
          blocking_task_refs: imported_task.blocking_task_refs,
          priority: imported_task.priority,
          external_task_id: imported_task.external_task_id,
          verification_source_ref: imported_task.verification_source_ref,
          automation_enabled: automation_enabled
        )
      end

      def build_reconciled_task(ref:, kind:, edit_scope:, verification_scope:, status:, current_run_ref:, parent_ref:, child_refs:, blocking_task_refs:, priority:, external_task_id:, verification_source_ref: nil, automation_enabled: true)
        A3::Domain::Task.new(
          ref: ref,
          kind: kind,
          edit_scope: edit_scope,
          verification_scope: verification_scope,
          status: status,
          current_run_ref: current_run_ref,
          parent_ref: parent_ref,
          child_refs: child_refs,
          blocking_task_refs: blocking_task_refs,
          priority: priority,
          external_task_id: external_task_id,
          verification_source_ref: verification_source_ref,
          automation_enabled: automation_enabled
        )
      end

      def reconcile_parent_ref(existing_task:, imported_task:)
        imported_task.parent_ref || existing_task.parent_ref
      end

      def reconcile_child_refs(existing_task:, imported_task:)
        return imported_task.child_refs if existing_task.kind == :parent || imported_task.kind == :parent
        (existing_task.child_refs + imported_task.child_refs).uniq.sort.freeze
      end

      def reconcile_kind(existing_task:, imported_task:)
        child_refs = reconcile_child_refs(existing_task: existing_task, imported_task: imported_task)
        parent_ref = reconcile_parent_ref(existing_task: existing_task, imported_task: imported_task)
        return :parent unless child_refs.empty?
        return :child if parent_ref

        imported_task.kind
      end

      def preserve_existing_topology(existing_task, refreshed_task)
        build_reconciled_task(
          ref: refreshed_task.ref,
          kind: preserved_kind(existing_task: existing_task, refreshed_task: refreshed_task),
          edit_scope: refreshed_task.edit_scope,
          verification_scope: refreshed_task.verification_scope,
          status: refreshed_task.status,
          current_run_ref: refreshed_task.current_run_ref,
          parent_ref: preserve_parent_ref(existing_task: existing_task, refreshed_task: refreshed_task),
          child_refs: preserve_child_refs(existing_task: existing_task, refreshed_task: refreshed_task),
          blocking_task_refs: refreshed_task.blocking_task_refs,
          priority: refreshed_task.priority,
          external_task_id: refreshed_task.external_task_id,
          verification_source_ref: existing_task.verification_source_ref,
          automation_enabled: preserve_existing_automation_enabled?(existing_task, refreshed_task) ? existing_task.automation_enabled : refreshed_task.automation_enabled
        )
      end

      def preserve_parent_ref(existing_task:, refreshed_task:)
        refreshed_task.parent_ref || existing_task.parent_ref
      end

      def preserve_child_refs(existing_task:, refreshed_task:)
        return existing_task.child_refs unless refreshed_task.child_refs.any?

        refreshed_task.child_refs
      end

      def preserved_kind(existing_task:, refreshed_task:)
        child_refs = preserve_child_refs(existing_task: existing_task, refreshed_task: refreshed_task)
        parent_ref = preserve_parent_ref(existing_task: existing_task, refreshed_task: refreshed_task)
        return :parent unless child_refs.empty?
        return :child if parent_ref

        refreshed_task.kind
      end

      def active_task?(task)
        task && !task.current_run_ref.nil?
      end

      def preserve_existing_automation_enabled?(existing_task, imported_task)
        existing_task &&
          existing_task.automation_enabled &&
          managed_nonterminal_task?(existing_task) &&
          !imported_task.automation_enabled
      end

      def reconcile_automation_enabled(existing_task, imported_task)
        return existing_task.automation_enabled if preserve_existing_automation_enabled?(existing_task, imported_task)
        return true if recover_direct_trigger_selected_automation_enabled?(existing_task, imported_task)

        imported_task.automation_enabled
      end

      def recover_direct_trigger_selected_automation_enabled?(existing_task, imported_task)
        return false unless existing_task
        return false unless managed_nonterminal_task?(existing_task)
        return false if imported_task.automation_enabled
        return false unless imported_task.external_task_id
        return false unless @external_task_source.respond_to?(:fetch_by_external_task_id)

        direct_task = @external_task_source.fetch_by_external_task_id(imported_task.external_task_id)
        direct_task && direct_task.ref == imported_task.ref && direct_task.automation_enabled
      end

      def managed_nonterminal_task?(task)
        !%i[todo done].include?(task.status)
      end

      def terminal_task?(task)
        task.status == :done
      end

      def fetch_existing_task(task_ref)
        @task_repository.fetch(task_ref)
      rescue A3::Domain::RecordNotFound
        nil
      end
    end
  end
end
