# frozen_string_literal: true

require "time"

module A3
  module Application
    class SharedRefLockGuard
      def initialize(lock_repository:, clock: -> { Time.now.utc.iso8601 })
        @lock_repository = lock_repository
        @clock = clock
      end

      def with_locks(lock_requests)
        locks = []
        sorted_lock_requests(lock_requests).each do |request|
          locks << @lock_repository.acquire(
            operation: request.fetch(:operation),
            repo_slot: request.fetch(:repo_slot),
            target_ref: request.fetch(:target_ref),
            run_ref: request.fetch(:run_ref),
            project_key: request[:project_key],
            claimed_at: @clock.call
          )
        end
        yield
      rescue A3::Domain::SharedRefLockConflict => e
        lock_conflict_result(e)
      ensure
        locks&.reverse_each { |lock| @lock_repository.release(lock_ref: lock.lock_ref) }
      end

      private

      def sorted_lock_requests(lock_requests)
        lock_requests.sort_by do |request|
          [
            request.fetch(:repo_slot).to_s,
            request.fetch(:target_ref).to_s,
            request.fetch(:operation).to_s
          ]
        end
      end

      def lock_conflict_result(error)
        A3::Application::ExecutionResult.new(
          success: false,
          summary: error.message,
          failing_command: "shared_ref_lock",
          observed_state: "waiting_for_shared_ref_lock",
          diagnostics: {
            "holder_ref" => error.holder_ref
          }.compact
        )
      end
    end
  end
end
