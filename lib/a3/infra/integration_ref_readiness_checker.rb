# frozen_string_literal: true

require "open3"
require "pathname"

module A3
  module Infra
    class IntegrationRefReadinessChecker
      Result = Struct.new(:ready, :missing_slots, :ref, keyword_init: true) do
        def ready?
          !!ready
        end

        def diagnostic_summary
          return "integration ref ready" if ready?

          "missing integration ref #{ref} for slots #{missing_slots.join(',')}"
        end
      end

      def initialize(repo_sources:)
        @repo_sources = repo_sources.transform_keys(&:to_sym).transform_values { |value| Pathname(value) }.freeze
      end

      def check(ref:, repo_slots:)
        missing_slots = Array(repo_slots).map(&:to_sym).each_with_object([]) do |slot, missing|
          source_root = @repo_sources.fetch(slot)
          missing << slot unless ref_exists?(source_root, ref)
        end

        Result.new(
          ready: missing_slots.empty?,
          missing_slots: missing_slots.freeze,
          ref: ref
        )
      end

      private

      def ref_exists?(source_root, ref)
        _stdout, _stderr, status = Open3.capture3("git", "-C", source_root.to_s, "rev-parse", "--verify", ref.to_s)
        status.success?
      end
    end
  end
end
