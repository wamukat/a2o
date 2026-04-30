# frozen_string_literal: true

require "securerandom"

module A3
  module Infra
    class InMemorySchedulerTaskClaimRepository
      include A3::Domain::SchedulerTaskClaimRepository

      def initialize(claim_ref_generator: -> { SecureRandom.uuid })
        @claim_ref_generator = claim_ref_generator
        @records = {}
      end

      def claim_task(task_ref:, phase:, parent_group_key:, claimed_by:, claimed_at:, project_key: A3::Domain::ProjectIdentity.current)
        project_key = A3::Domain::ProjectIdentity.normalize(project_key)
        assert_no_active_conflict!(project_key: project_key, task_ref: task_ref, parent_group_key: parent_group_key)
        claim = A3::Domain::SchedulerTaskClaimRecord.new(
          claim_ref: @claim_ref_generator.call,
          project_key: project_key,
          task_ref: task_ref,
          phase: phase,
          parent_group_key: parent_group_key,
          state: :claimed,
          claimed_by: claimed_by,
          claimed_at: claimed_at
        )
        @records[claim.claim_ref] = claim
        claim
      end

      def link_run(claim_ref:, run_ref:)
        update(claim_ref) { |claim| claim.link_run(run_ref: run_ref) }
      end

      def release_claim(claim_ref:, run_ref: nil)
        update(claim_ref) { |claim| claim.release(run_ref: run_ref) }
      end

      def heartbeat(claim_ref:, heartbeat_at:)
        update(claim_ref) { |claim| claim.heartbeat(heartbeat_at: heartbeat_at) }
      end

      def mark_claim_stale(claim_ref:, reason:)
        update(claim_ref) { |claim| claim.mark_stale(reason: reason) }
      end

      def fetch(claim_ref)
        @records.fetch(claim_ref)
      rescue KeyError
        raise A3::Domain::RecordNotFound, "Scheduler task claim not found: #{claim_ref}"
      end

      def all
        @records.values.sort_by(&:claim_ref).freeze
      end

      def active_claims(project_key: nil)
        normalized_project_key = A3::Domain::ProjectIdentity.normalize(project_key)
        all.select do |claim|
          claim.active? && (normalized_project_key.nil? || claim.project_key == normalized_project_key)
        end.freeze
      end

      private

      def update(claim_ref)
        claim = fetch(claim_ref)
        updated = yield claim
        @records[claim_ref] = updated
        updated
      end

      def assert_no_active_conflict!(project_key:, task_ref:, parent_group_key:)
        active_claims(project_key: project_key).each do |claim|
          if claim.task_ref == task_ref.to_s
            raise A3::Domain::SchedulerTaskClaimConflict, "scheduler task claim conflict: active task #{task_ref}"
          end
          if claim.parent_group_key == parent_group_key.to_s
            raise A3::Domain::SchedulerTaskClaimConflict, "scheduler task claim conflict: active parent group #{parent_group_key}"
          end
        end
      end
    end
  end
end
