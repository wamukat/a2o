# frozen_string_literal: true

module A3
  module Application
    class BuildArtifactOwner
      def call(task:, snapshot_version:)
        A3::Domain::ArtifactOwner.new(
          owner_ref: task.parent_ref || task.ref,
          owner_scope: task.kind == :parent ? :parent : :task,
          snapshot_version: snapshot_version
        )
      end
    end
  end
end
