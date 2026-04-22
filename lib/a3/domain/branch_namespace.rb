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
    end
  end
end
