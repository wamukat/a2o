# frozen_string_literal: true

module A3
  module Application
    class BuildScopeSnapshot
      def call(task:)
        A3::Domain::ScopeSnapshot.new(
          edit_scope: task.edit_scope,
          verification_scope: task.verification_scope,
          ownership_scope: task.kind == :parent ? :parent : :task
        )
      end
    end
  end
end
