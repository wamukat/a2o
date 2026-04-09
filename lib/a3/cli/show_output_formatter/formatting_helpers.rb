# frozen_string_literal: true

module A3
  module CLI
    module ShowOutputFormatter
      module FormattingHelpers
        module_function

        def diagnostic_value(value)
          case value
          when Hash, Array
            value.inspect
          else
            value.to_s
          end
        end
      end
    end
  end
end
