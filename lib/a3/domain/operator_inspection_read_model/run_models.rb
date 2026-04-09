# frozen_string_literal: true

require_relative "runtime_package_recovery_attributes"
require_relative "recovery_snapshot"
require_relative "evidence_summary"
require_relative "run_view/recovery_view"
require_relative "run_view/blocked_diagnosis_snapshot"
require_relative "run_view/runtime_snapshot"
require_relative "run_view/execution_snapshot"
require_relative "run_view"

module A3
  module Domain
    class OperatorInspectionReadModel
      RunInspection = RunView
    end
  end
end
