# frozen_string_literal: true

module A3
  module Domain
    module TaskMetricsRepository
      def save(_record)
        raise NotImplementedError, "#{self.class} must implement #save"
      end

      def all
        raise NotImplementedError, "#{self.class} must implement #all"
      end
    end
  end
end
