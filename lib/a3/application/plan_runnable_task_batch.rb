# frozen_string_literal: true

require "a3/domain/runnable_task_assessment"
require "a3/domain/scheduler_conflict_keys"
require "a3/domain/scheduler_selection_policy"

module A3
  module Application
    class PlanRunnableTaskBatch
      Candidate = Struct.new(:task, :phase, :assessment, :conflict_keys, keyword_init: true)
      SkippedConflict = Struct.new(:task_ref, :phase, :reason, :conflict_key, :holder_ref, keyword_init: true)
      Result = Struct.new(
        :candidates,
        :skipped_conflicts,
        :assessments,
        :active_slot_count,
        :available_slot_count,
        keyword_init: true
      ) do
        def selected_assessments
          candidates.map(&:assessment).freeze
        end

        def busy?
          available_slot_count <= 0
        end

        def idle?
          candidates.empty? && skipped_conflicts.empty? && !busy? && assessments.none?(&:runnable?)
        end

        def waiting?
          candidates.empty? && !skipped_conflicts.empty? && !busy?
        end
      end

      def initialize(
        task_repository:,
        run_repository:,
        task_claim_repository:,
        max_parallel_tasks:,
        sync_external_tasks: nil,
        scheduler_selection_policy: A3::Domain::SchedulerSelectionPolicy.new
      )
        @task_repository = task_repository
        @run_repository = run_repository
        @task_claim_repository = task_claim_repository
        @max_parallel_tasks = Integer(max_parallel_tasks)
        @sync_external_tasks = sync_external_tasks
        @scheduler_selection_policy = scheduler_selection_policy
      end

      def call
        @sync_external_tasks&.call
        tasks = @task_repository.all
        assessments = tasks.map { |task| A3::Domain::RunnableTaskAssessment.evaluate(task: task, tasks: tasks) }.freeze
        active_reservations = active_reservations_for(tasks: tasks)
        available_slot_count = [@max_parallel_tasks - active_reservations.task_refs.size, 0].max
        if available_slot_count.zero?
          return result(
            candidates: [],
            skipped_conflicts: [],
            assessments: assessments,
            active_reservations: active_reservations,
            available_slot_count: available_slot_count
          )
        end

        selected = []
        skipped = []
        reserved = active_reservations.dup
        sorted = @scheduler_selection_policy.sort_assessments(
          assessments: assessments.select(&:runnable?),
          tasks: tasks
        )

        sorted.each do |assessment|
          break if selected.size >= available_slot_count

          keys = A3::Domain::SchedulerConflictKeys.for_task(task: assessment.task, tasks: tasks)
          conflict = first_conflict(keys: keys, reservations: reserved)
          if conflict
            skipped << SkippedConflict.new(
              task_ref: assessment.task_ref,
              phase: assessment.phase,
              reason: conflict.fetch(:reason),
              conflict_key: conflict.fetch(:key),
              holder_ref: conflict.fetch(:holder_ref)
            )
            next
          end

          reserve!(reservations: reserved, task_ref: assessment.task_ref, keys: keys)
          selected << Candidate.new(
            task: assessment.task,
            phase: assessment.phase,
            assessment: assessment,
            conflict_keys: keys
          )
        end

        result(
          candidates: selected.freeze,
          skipped_conflicts: skipped.freeze,
          assessments: assessments,
          active_reservations: active_reservations,
          available_slot_count: available_slot_count
        )
      end

      private

      Reservations = Struct.new(:task_refs, :parent_group_keys, keyword_init: true) do
        def dup
          self.class.new(task_refs: task_refs.dup, parent_group_keys: parent_group_keys.dup)
        end
      end

      def result(candidates:, skipped_conflicts:, assessments:, active_reservations:, available_slot_count:)
        Result.new(
          candidates: candidates,
          skipped_conflicts: skipped_conflicts,
          assessments: assessments,
          active_slot_count: active_reservations.task_refs.size,
          available_slot_count: available_slot_count
        )
      end

      def active_reservations_for(tasks:)
        reservations = Reservations.new(task_refs: {}, parent_group_keys: {})
        task_index = tasks.each_with_object({}) { |task, memo| memo[task.ref] = task }

        @task_claim_repository.active_claims.each do |claim|
          reserve_task_key!(
            reservations: reservations,
            key: "task:#{claim.task_ref}",
            holder_ref: claim.claim_ref,
            reason: :active_claim
          )
          reserve_parent_group_key!(
            reservations: reservations,
            key: claim.parent_group_key,
            holder_ref: claim.claim_ref,
            reason: :active_claim
          )
        end

        @run_repository.all.reject(&:terminal?).each do |run|
          task = task_index[run.task_ref]
          next unless task

          keys = A3::Domain::SchedulerConflictKeys.for_task(task: task, tasks: tasks)
          reserve_task_key!(
            reservations: reservations,
            key: keys.task_key,
            holder_ref: run.ref,
            reason: :active_run
          )
          reserve_parent_group_key!(
            reservations: reservations,
            key: keys.parent_group_key,
            holder_ref: run.ref,
            reason: :active_run
          )
        end

        reservations
      end

      def reserve!(reservations:, task_ref:, keys:)
        reserve_task_key!(
          reservations: reservations,
          key: keys.task_key,
          holder_ref: task_ref,
          reason: :in_batch
        )
        reserve_parent_group_key!(
          reservations: reservations,
          key: keys.parent_group_key,
          holder_ref: task_ref,
          reason: :in_batch
        )
      end

      def first_conflict(keys:, reservations:)
        reservations.task_refs[keys.task_key] ||
          reservations.parent_group_keys[keys.parent_group_key]
      end

      def reserve_task_key!(reservations:, key:, holder_ref:, reason:)
        reservations.task_refs[key] ||= reservation(key: key, holder_ref: holder_ref, reason: reason)
      end

      def reserve_parent_group_key!(reservations:, key:, holder_ref:, reason:)
        reservations.parent_group_keys[key] ||= reservation(key: key, holder_ref: holder_ref, reason: reason)
      end

      def reservation(key:, holder_ref:, reason:)
        { key: key, holder_ref: holder_ref, reason: reason }
      end
    end
  end
end
