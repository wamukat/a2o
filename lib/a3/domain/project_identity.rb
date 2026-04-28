# frozen_string_literal: true

module A3
  module Domain
    module ProjectIdentity
      module_function

      def normalize(value)
        normalized = value.to_s.strip
        normalized.empty? ? nil : normalized.freeze
      end

      def current
        normalize(ENV["A2O_PROJECT_KEY"])
      end

      def require_readable!(project_key:, record_type:)
        return if normalize(project_key)
        return unless ENV["A2O_MULTI_PROJECT_MODE"].to_s == "1"

        raise ConfigurationError,
          "#{record_type} legacy record without project_key is ambiguous in multi-project mode; migrate runtime records before enabling multi-project writes"
      end
    end
  end
end
