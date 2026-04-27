# frozen_string_literal: true

module A3
  module Infra
    class NullExternalTaskActivityPublisher
      def publish(task_ref:, body:, external_task_id: nil, event: nil)
        nil
      end
    end
  end
end
