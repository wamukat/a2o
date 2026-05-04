# frozen_string_literal: true

module A3
  module Domain
    class ReviewDisposition
      KINDS = %i[completed follow_up_child blocked].freeze

      attr_reader :kind, :slot_scopes, :summary, :description, :finding_key

      def initialize(kind:, slot_scopes:, summary:, description:, finding_key:)
        @kind = kind.to_sym
        @slot_scopes = Array(slot_scopes).map(&:to_s).reject(&:empty?).map(&:to_sym).uniq.freeze
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
          slot_scopes: payload.fetch("slot_scopes"),
          summary: payload.fetch("summary"),
          description: payload.fetch("description"),
          finding_key: payload["finding_key"]
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
          !slot_scopes.empty? &&
          !summary.strip.empty? &&
          !description.strip.empty? &&
          (completed? || !finding_key.strip.empty?)
      end
    end
  end
end
