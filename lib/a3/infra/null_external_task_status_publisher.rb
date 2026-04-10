# frozen_string_literal: true

module A3
  module Infra
    class NullExternalTaskStatusPublisher
      def publish(task_ref:, status:, external_task_id: nil, task_kind: nil)
        nil
      end
    end
  end
end
