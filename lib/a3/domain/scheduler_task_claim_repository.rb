# frozen_string_literal: true

module A3
  module Domain
    module SchedulerTaskClaimRepository
      def claim_task(task_ref:, phase:, parent_group_key:, claimed_by:, claimed_at:, project_key: A3::Domain::ProjectIdentity.current)
        raise NotImplementedError, "#{self.class} must implement #claim_task"
      end

      def link_run(claim_ref:, run_ref:)
        raise NotImplementedError, "#{self.class} must implement #link_run"
      end

      def release_claim(claim_ref:, run_ref: nil)
        raise NotImplementedError, "#{self.class} must implement #release_claim"
      end

      def heartbeat(claim_ref:, heartbeat_at:)
        raise NotImplementedError, "#{self.class} must implement #heartbeat"
      end

      def mark_claim_stale(claim_ref:, reason:)
        raise NotImplementedError, "#{self.class} must implement #mark_claim_stale"
      end

      def fetch(claim_ref)
        raise NotImplementedError, "#{self.class} must implement #fetch"
      end

      def all
        raise NotImplementedError, "#{self.class} must implement #all"
      end

      def active_claims(project_key: nil)
        raise NotImplementedError, "#{self.class} must implement #active_claims"
      end
    end
  end
end
