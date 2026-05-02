# frozen_string_literal: true

require "a3/domain/delivery_config"

module A3
  module Domain
    class MergePlan
      attr_reader :project_key, :task_ref, :run_ref, :merge_source, :integration_target, :merge_policy, :merge_slots, :delivery_config, :external_task_id

      def initialize(task_ref:, run_ref:, merge_source:, integration_target:, merge_policy:, merge_slots:, project_key: A3::Domain::ProjectIdentity.current, delivery_config: A3::Domain::DeliveryConfig.local_merge, external_task_id: nil)
        @project_key = A3::Domain::ProjectIdentity.normalize(project_key)
        @task_ref = task_ref
        @run_ref = run_ref
        @merge_source = merge_source
        @integration_target = integration_target
        @merge_policy = merge_policy.to_sym
        @merge_slots = Array(merge_slots).map(&:to_sym).freeze
        @delivery_config = delivery_config
        @external_task_id = external_task_id
        freeze
      end
    end
  end
end
