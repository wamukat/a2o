# frozen_string_literal: true

module A3
  module Domain
    class MergePlan
      attr_reader :project_key, :task_ref, :run_ref, :merge_source, :integration_target, :merge_policy, :merge_slots

      def initialize(task_ref:, run_ref:, merge_source:, integration_target:, merge_policy:, merge_slots:, project_key: A3::Domain::ProjectIdentity.current)
        @project_key = A3::Domain::ProjectIdentity.normalize(project_key)
        @task_ref = task_ref
        @run_ref = run_ref
        @merge_source = merge_source
        @integration_target = integration_target
        @merge_policy = merge_policy.to_sym
        @merge_slots = Array(merge_slots).map(&:to_sym).freeze
        freeze
      end
    end
  end
end
