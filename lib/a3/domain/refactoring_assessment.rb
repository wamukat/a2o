# frozen_string_literal: true

module A3
  module Domain
    class RefactoringAssessment
      DISPOSITIONS = %w[none include_child defer_follow_up blocked_by_design_debt needs_clarification].freeze
      RECOMMENDED_ACTIONS = %w[
        none
        document_only
        include_in_current_child
        create_refactoring_child
        create_follow_up_child
        request_clarification
        block_until_decision
      ].freeze
      RISKS = %w[low medium high unknown].freeze

      attr_reader :disposition, :reason, :scope, :recommended_action, :risk, :evidence

      def initialize(disposition:, reason: nil, scope: [], recommended_action: nil, risk: nil, evidence: [])
        @disposition = disposition.to_s.strip
        @reason = normalize_optional_string(reason)
        @scope = normalize_string_array(scope)
        @recommended_action = normalize_optional_string(recommended_action)
        @risk = normalize_optional_string(risk)
        @evidence = normalize_string_array(evidence)
        freeze
      end

      def self.from_persisted_form(value)
        return nil unless value.is_a?(Hash)

        new(
          disposition: value["disposition"],
          reason: value["reason"],
          scope: value.fetch("scope", []),
          recommended_action: value["recommended_action"],
          risk: value["risk"],
          evidence: value.fetch("evidence", [])
        )
      end

      def self.from_response_bundle(bundle)
        return nil unless bundle.is_a?(Hash)

        from_persisted_form(bundle["refactoring_assessment"])
      rescue ArgumentError
        nil
      end

      def self.validation_errors(value, field: "refactoring_assessment")
        return [] if value.nil?
        return ["#{field} must be an object when present"] unless value.is_a?(Hash)

        assessment = from_persisted_form(value)
        errors = []
        errors << "#{field}.disposition must be one of #{DISPOSITIONS.join(', ')}" unless DISPOSITIONS.include?(assessment.disposition)
        errors << "#{field}.reason must be a non-empty string for #{assessment.disposition}" if assessment.reason_required? && !assessment.reason
        if assessment.recommended_action_required? && !assessment.recommended_action
          errors << "#{field}.recommended_action must be present for #{assessment.disposition}"
        end
        if assessment.recommended_action && !RECOMMENDED_ACTIONS.include?(assessment.recommended_action)
          errors << "#{field}.recommended_action must be one of #{RECOMMENDED_ACTIONS.join(', ')}"
        end
        errors << "#{field}.risk must be one of #{RISKS.join(', ')}" if assessment.risk && !RISKS.include?(assessment.risk)
        validate_string_array(value, "scope", "#{field}.scope").each { |error| errors << error }
        validate_string_array(value, "evidence", "#{field}.evidence").each { |error| errors << error }
        errors
      rescue ArgumentError => e
        [e.message]
      end

      def valid?
        self.class.validation_errors(persisted_form).empty?
      end

      def reason_required?
        disposition != "none"
      end

      def recommended_action_required?
        disposition != "none"
      end

      def active?
        disposition != "none" || !!reason || !scope.empty? || !evidence.empty?
      end

      def persisted_form
        compact_hash(
          "disposition" => disposition,
          "reason" => reason,
          "scope" => scope,
          "recommended_action" => recommended_action,
          "risk" => risk,
          "evidence" => evidence
        )
      end

      def summary
        parts = []
        parts << disposition
        parts << "action=#{recommended_action}" if recommended_action
        parts << "risk=#{risk}" if risk
        parts << "scope=#{scope.join(',')}" unless scope.empty?
        parts << "reason=#{reason}" if reason
        parts.join(" ")
      end

      private

      def normalize_optional_string(value)
        normalized = value.to_s.strip
        normalized.empty? ? nil : normalized
      end

      def normalize_string_array(value)
        Array(value).map(&:to_s).map(&:strip).reject(&:empty?).freeze
      end

      def compact_hash(value)
        value.reject { |_, item| item.nil? || (item.respond_to?(:empty?) && item.empty?) }
      end

      def self.validate_string_array(value, key, field)
        return [] unless value.key?(key)
        return [] if value[key].is_a?(Array) && value[key].all? { |entry| entry.is_a?(String) && !entry.strip.empty? }

        ["#{field} must be an array of non-empty strings when present"]
      end
    end
  end
end
