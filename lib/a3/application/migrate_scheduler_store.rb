# frozen_string_literal: true

module A3
  module Application
    class MigrateSchedulerStore
      Result = Struct.new(:status, :migration_state, :marker_path, :message, keyword_init: true)

      def initialize(runtime_package:, migration_marker_store: A3::Infra::LocalMigrationMarkerStore.new)
        @runtime_package = runtime_package
        @migration_marker_store = migration_marker_store
      end

      def call
        case @runtime_package.scheduler_store_migration_state
        when :not_required
          Result.new(
            status: :not_required,
            migration_state: :not_required,
            marker_path: @runtime_package.migration_marker_path,
            message: "scheduler store migration not required"
          ).freeze
        when :applied
          marker_path = @migration_marker_store.mark_applied(@runtime_package)
          Result.new(
            status: :already_applied,
            migration_state: :applied,
            marker_path: marker_path,
            message: "scheduler store migration already applied"
          ).freeze
        when :pending
          marker_path = @migration_marker_store.mark_applied(@runtime_package)
          Result.new(
            status: :applied,
            migration_state: :applied,
            marker_path: marker_path,
            message: "scheduler store migration marker written"
          ).freeze
        else
          raise A3::Domain::ConfigurationError, "unsupported scheduler store migration state: #{@runtime_package.scheduler_store_migration_state.inspect}"
        end
      end
    end
  end
end
