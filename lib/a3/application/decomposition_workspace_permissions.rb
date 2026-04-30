# frozen_string_literal: true

require "fileutils"

module A3
  module Application
    module DecompositionWorkspacePermissions
      SHARED_WORKSPACE_DIR_MODE = 0o777

      private

      def make_shared_workspace_dir(path)
        FileUtils.mkdir_p(path)
        FileUtils.chmod(SHARED_WORKSPACE_DIR_MODE, path)
      end

      def make_shared_workspace_tree(path)
        return unless path && File.exist?(path)

        FileUtils.chmod_R("a+rwX", path)
      end
    end
  end
end
