# frozen_string_literal: true

module A3
  module CLI
    module ShowOutputFormatter
      module RunOutput
        module_function

        def lines(run)
          RunFormatter.lines(run)
        end

        def blocked_diagnosis_lines(result)
          BlockedDiagnosisFormatter.lines(result)
        end
      end
    end
  end
end
