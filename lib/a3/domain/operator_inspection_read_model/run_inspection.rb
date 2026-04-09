# frozen_string_literal: true

module A3
  module Domain
    class OperatorInspectionReadModel
      module RunInspection
        module_function

        def from_run(run, recovery:)
          RunView.from_run(run, recovery: recovery)
        end
      end
    end
  end
end
