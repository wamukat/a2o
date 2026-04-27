# frozen_string_literal: true

module A3
  module Domain
    module BranchNamespace
      module_function

      def normalize(value)
        normalized = value.to_s.strip.gsub(%r{[^A-Za-z0-9._/-]}, "-").gsub(%r{/+}, "/").gsub(%r{\A/+|/+\z}, "")
        normalized = normalized.split("/").map { |part| part.sub(/\Aa3(?:-|\z)/, "") }.reject(&:empty?).join("/")
        normalized.empty? ? nil : normalized
      end

      def from_env
        value = ENV["A2O_BRANCH_NAMESPACE"]
        return value unless value.to_s.strip.empty?

        legacy_value = ENV["A3_BRANCH_NAMESPACE"]
        return nil if legacy_value.to_s.strip.empty?

        raise A3::Domain::ConfigurationError,
              "removed A3 compatibility input: environment variable A3_BRANCH_NAMESPACE; " \
              "migration_required=true replacement=environment variable A2O_BRANCH_NAMESPACE"
      end
    end
  end
end
