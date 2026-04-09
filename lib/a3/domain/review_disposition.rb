# frozen_string_literal: true

module A3
  module Domain
    class ReviewDisposition
      KINDS = %i[completed follow_up_child blocked].freeze
      REPO_SCOPES = %i[repo_alpha repo_beta both unresolved].freeze

      attr_reader :kind, :repo_scope, :summary, :description, :finding_key

      def initialize(kind:, repo_scope:, summary:, description:, finding_key:)
        @kind = kind.to_sym
        @repo_scope = repo_scope.to_sym
        @summary = summary.to_s
        @description = description.to_s
        @finding_key = finding_key.to_s
        freeze
      end

      def self.from_response_bundle(bundle)
        return nil unless bundle.is_a?(Hash)

        payload = bundle["review_disposition"]
        return nil unless payload.is_a?(Hash)

        new(
          kind: payload.fetch("kind"),
          repo_scope: payload.fetch("repo_scope"),
          summary: payload.fetch("summary"),
          description: payload.fetch("description"),
          finding_key: payload.fetch("finding_key")
        )
      rescue KeyError
        nil
      end

      def follow_up_child?
        kind == :follow_up_child
      end

      def blocked?
        kind == :blocked
      end

      def completed?
        kind == :completed
      end

      def valid?
        KINDS.include?(kind) &&
          REPO_SCOPES.include?(repo_scope) &&
          !summary.strip.empty? &&
          !description.strip.empty? &&
          !finding_key.strip.empty?
      end
    end
  end
end
