# frozen_string_literal: true

module A3
  module Infra
    class NullExternalTaskStatusPublisher
      def publish(task_ref:, status:, external_task_id: nil, task_kind: nil, status_reason: nil, status_details: nil)
        nil
      end

      def blocked?(task_ref:, external_task_id: nil)
        false
      end
    end
  end
end
