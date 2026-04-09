# frozen_string_literal: true

module A3
  module Infra
    class LocalMigrationMarkerStore
      def applied?(runtime_package)
        runtime_package.migration_marker_path.file?
      end

      def mark_applied(runtime_package)
        marker_path = runtime_package.migration_marker_path
        FileUtils.mkdir_p(marker_path.dirname)
        File.write(marker_path, "applied\n")
        marker_path
      end
    end
  end
end
