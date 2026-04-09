# frozen_string_literal: true

module A3
  module Domain
    module DeepFreezable
      private

      def deep_freeze_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested_value), frozen_hash|
            frozen_hash[deep_freeze_value(key)] = deep_freeze_value(nested_value)
          end.freeze
        when Array
          value.map { |element| deep_freeze_value(element) }.freeze
        else
          value.freeze
        end
      end
    end
  end
end
