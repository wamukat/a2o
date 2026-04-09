# frozen_string_literal: true

module A3
  module Domain
    class OperatorInspectionReadModel
      class TaskTopology
        attr_reader :parent, :children

        def initialize(parent:, children:)
          @parent = parent
          @children = Array(children).freeze
          freeze
        end

        def self.from_task_and_tasks(task:, tasks:)
          parent = TaskRelation.from_task(tasks.find { |candidate| candidate.ref == task.parent_ref })
          children = task.child_refs.map do |child_ref|
            TaskRelation.from_task(tasks.find { |candidate| candidate.ref == child_ref }) || TaskRelation.missing(child_ref)
          end

          new(parent: parent, children: children)
        end

        def ==(other)
          other.is_a?(self.class) &&
            other.parent == parent &&
            other.children == children
        end
        alias eql? ==
      end
    end
  end
end
