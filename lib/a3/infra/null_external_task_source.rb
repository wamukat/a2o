# frozen_string_literal: true

module A3
  module Infra
    class NullExternalTaskSource
      def load
        [].freeze
      end

      def fetch_task_packet_by_external_task_id(_task_id)
        nil
      end

      def fetch_task_packet_by_ref(_task_ref)
        nil
      end
    end
  end
end
