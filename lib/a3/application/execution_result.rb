# frozen_string_literal: true

module A3
  module Application
    class ExecutionResult
      attr_reader :success, :summary, :failing_command, :observed_state, :diagnostics, :response_bundle

      def initialize(success:, summary:, failing_command: nil, observed_state: nil, diagnostics: {}, response_bundle: nil)
        @success = success
        @summary = summary
        @failing_command = failing_command
        @observed_state = observed_state
        @diagnostics = diagnostics.freeze
        @response_bundle = response_bundle
        freeze
      end

      def success?
        @success
      end

      def rework_required?
        response_bundle.is_a?(Hash) && response_bundle["rework_required"] == true
      end

      def review_disposition
        return nil unless response_bundle.is_a?(Hash)

        disposition = A3::Domain::ReviewDisposition.from_response_bundle(response_bundle)
        return disposition if disposition&.valid?

        nil
      end
    end
  end
end
