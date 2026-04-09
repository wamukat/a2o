# frozen_string_literal: true

module A3
  module Infra
    class InMemoryRunRepository
      include A3::Domain::RunRepository

      def initialize
        @runs = {}
      end

      def save(run)
        @runs[run.ref] = run
      end

      def fetch(run_ref)
        @runs.fetch(run_ref)
      rescue KeyError
        raise A3::Domain::RecordNotFound, "Run not found: #{run_ref}"
      end

      def all
        @runs.values.freeze
      end
    end
  end
end
