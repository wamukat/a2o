# frozen_string_literal: true

module A3
  module Infra
    class NullExternalTaskSnapshotReader
      def load(task_ids: [], task_refs: [])
        A3::Infra::KanbanCliTaskSnapshotReader::SnapshotIndex.new(by_ref: {}.freeze, by_id: {}.freeze)
      end
    end
  end
end
