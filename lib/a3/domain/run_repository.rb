# frozen_string_literal: true

module A3
  module Domain
    module RunRepository
      def save(_run)
        raise NotImplementedError, "#{self.class} must implement #save"
      end

      def fetch(_run_ref)
        raise NotImplementedError, "#{self.class} must implement #fetch"
      end

      def all
        # Returns runs in persistence order (oldest first). Watch surfaces use this
        # sequence as the canonical tie-breaker when multiple runs exist per task.
        raise NotImplementedError, "#{self.class} must implement #all"
      end
    end
  end
end
