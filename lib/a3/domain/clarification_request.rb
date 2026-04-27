# frozen_string_literal: true

module A3
  module Domain
    class ClarificationRequest
      attr_reader :question, :context, :options, :recommended_option, :impact

      def initialize(question:, context: nil, options: [], recommended_option: nil, impact: nil)
        @question = normalize_required_string(question, "question")
        @context = normalize_optional_string(context)
        @options = Array(options).map { |option| normalize_required_string(option, "options") }.freeze
        @recommended_option = normalize_optional_string(recommended_option)
        @impact = normalize_optional_string(impact)
        freeze
      end

      def self.from_response_bundle(bundle)
        return nil unless bundle.is_a?(Hash)

        from_persisted_form(bundle["clarification_request"])
      rescue ArgumentError
        nil
      end

      def self.from_persisted_form(value)
        return nil unless value.is_a?(Hash)

        new(
          question: value["question"],
          context: value["context"],
          options: value.fetch("options", []),
          recommended_option: value["recommended_option"],
          impact: value["impact"]
        )
      end

      def persisted_form
        {
          "question" => question,
          "context" => context,
          "options" => options,
          "recommended_option" => recommended_option,
          "impact" => impact
        }
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.question == question &&
          other.context == context &&
          other.options == options &&
          other.recommended_option == recommended_option &&
          other.impact == impact
      end
      alias eql? ==

      private

      def normalize_required_string(value, field)
        normalized = value.to_s.strip
        raise ArgumentError, "clarification_request.#{field} must be a non-empty string" if normalized.empty?

        normalized
      end

      def normalize_optional_string(value)
        normalized = value.to_s.strip
        normalized.empty? ? nil : normalized
      end
    end
  end
end
