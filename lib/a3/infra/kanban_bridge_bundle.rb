# frozen_string_literal: true

module A3
  module Infra
    KanbanBridgeBundle = Struct.new(
      :task_source,
      :task_status_publisher,
      :task_activity_publisher,
      :follow_up_child_writer,
      :task_snapshot_reader,
      keyword_init: true
    )
  end
end
