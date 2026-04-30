# frozen_string_literal: true

require "securerandom"

module A3
  module Infra
    class InMemorySharedRefLockRepository
      include A3::Domain::SharedRefLockRepository

      def initialize(lock_ref_generator: -> { SecureRandom.uuid })
        @lock_ref_generator = lock_ref_generator
        @locks = {}
        @mutex = Mutex.new
      end

      def acquire(operation:, repo_slot:, target_ref:, run_ref:, claimed_at:, project_key: A3::Domain::ProjectIdentity.current)
        @mutex.synchronize do
          lock = A3::Domain::SharedRefLockRecord.new(
            lock_ref: @lock_ref_generator.call,
            project_key: project_key,
            operation: operation,
            repo_slot: repo_slot,
            target_ref: target_ref,
            run_ref: run_ref,
            claimed_at: claimed_at
          )
          conflict = active_locks_unlocked(project_key: lock.project_key).find { |active| active.shared_ref_key == lock.shared_ref_key }
          if conflict
            raise A3::Domain::SharedRefLockConflict.new(
              "shared ref lock conflict: #{lock.shared_ref_key}",
              holder_ref: conflict.lock_ref
            )
          end

          @locks[lock.lock_ref] = lock
          lock
        end
      end

      def release(lock_ref:)
        @mutex.synchronize { @locks.delete(lock_ref) }
      end

      def active_locks(project_key: nil)
        @mutex.synchronize { active_locks_unlocked(project_key: project_key) }
      end

      private

      def active_locks_unlocked(project_key: nil)
        normalized_project_key = A3::Domain::ProjectIdentity.normalize(project_key)
        @locks.values.select do |lock|
          normalized_project_key.nil? || lock.project_key == normalized_project_key
        end.sort_by(&:lock_ref).freeze
      end
    end
  end
end
