# frozen_string_literal: true

module A3
  module Adapters
    module TaskMetricsRecord
      def self.dump(record)
        record.persisted_form
      end

      def self.load(record)
        A3::Domain::TaskMetricsRecord.from_persisted_form(record)
      end
    end
  end
end
