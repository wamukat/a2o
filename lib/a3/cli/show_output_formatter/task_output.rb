# frozen_string_literal: true

module A3
  module CLI
    module ShowOutputFormatter
      module TaskOutput
        module_function

        def lines(task)
          TaskFormatter.lines(task)
        end
      end
    end
  end
end
