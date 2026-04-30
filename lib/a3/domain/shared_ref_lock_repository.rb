# frozen_string_literal: true

module A3
  module Domain
    module SharedRefLockRepository
      def acquire(operation:, repo_slot:, target_ref:, run_ref:, claimed_at:, project_key: A3::Domain::ProjectIdentity.current)
        raise NotImplementedError, "#{self.class} must implement #acquire"
      end

      def release(lock_ref:)
        raise NotImplementedError, "#{self.class} must implement #release"
      end

      def active_locks(project_key: nil)
        raise NotImplementedError, "#{self.class} must implement #active_locks"
      end
    end
  end
end
