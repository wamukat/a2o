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

      def merge_recovery_required?
        response_bundle.is_a?(Hash) && response_bundle["merge_recovery_required"] == true
      end

      def merge_recovery_verification_required?
        response_bundle.is_a?(Hash) && response_bundle["merge_recovery_verification_required"] == true
      end

      def merge_recovery_verification_source_ref
        return nil unless response_bundle.is_a?(Hash)

        value = response_bundle["merge_recovery_verification_source_ref"]
        value.is_a?(String) && !value.empty? ? value : nil
      end

      def review_disposition
        return nil unless response_bundle.is_a?(Hash)

        disposition = A3::Domain::ReviewDisposition.from_response_bundle(response_bundle)
        return disposition if disposition&.valid?

        nil
      end

      def skill_feedback
        return [] if invalid_worker_result?
        return [] unless response_bundle.is_a?(Hash)

        value = response_bundle["skill_feedback"]
        case value
        when Hash
          [value]
        when Array
          value.select { |entry| entry.is_a?(Hash) }
        else
          []
        end
      end

      def invalid_worker_result?
        failing_command == "worker_result_schema" ||
          failing_command == "worker_result_json" ||
          observed_state == "invalid_worker_result"
      end

      def with_diagnostics(value)
        self.class.new(
          success: success?,
          summary: summary,
          failing_command: failing_command,
          observed_state: observed_state,
          diagnostics: value,
          response_bundle: response_bundle
        )
      end
    end
  end
end
