# frozen_string_literal: true

module A3
  module Domain
    module SourceRemote
      module_function

      def normalize(value)
        compact = compact_value(value)
        return nil unless compact.is_a?(Hash) && compact.any?

        compact
      end

      def compact_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), memo|
            normalized_key = key.to_s.strip
            next if normalized_key.empty?

            normalized_value = compact_value(child)
            next if blank_compact_value?(normalized_value)

            memo[normalized_key] = normalized_value
          end
        when Array
          value.map { |child| compact_value(child) }.reject { |child| blank_compact_value?(child) }
        when NilClass
          nil
        else
          text = value.to_s.strip
          text.empty? ? nil : text
        end
      end

      def blank_compact_value?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end
    end
  end
end
