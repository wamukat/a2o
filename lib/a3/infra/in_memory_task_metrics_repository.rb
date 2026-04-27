# frozen_string_literal: true

module A3
  module Infra
    class InMemoryTaskMetricsRepository
      include A3::Domain::TaskMetricsRepository

      def initialize
        @records = []
      end

      def save(record)
        @records << record
      end

      def all
        @records.dup.freeze
      end
    end
  end
end
