# frozen_string_literal: true

module A3
  module Application
    class RunRuntimeCanary
      Result = Struct.new(:status, :doctor_result, :migration_result, :scheduler_result, :next_execution_mode, :next_execution_mode_reason, :next_execution_mode_command, :operator_action, :operator_action_command, keyword_init: true)

      def initialize(runtime_package:, execute_until_idle:)
        @runtime_package = runtime_package
        @execute_until_idle = execute_until_idle
      end

      def call(project_context:, max_steps: 100)
        doctor_result = doctor_runtime
        migration_result = nil

        if doctor_result.startup_readiness == :blocked && doctor_result.startup_blockers == "scheduler_store_migration"
          migration_result = migrate_scheduler_store
          doctor_result = doctor_runtime
        end

        return Result.new(
          status: :blocked,
          doctor_result: doctor_result,
          migration_result: migration_result,
          scheduler_result: nil,
          next_execution_mode: :doctor_inspect,
          next_execution_mode_reason: "runtime canary is blocked; continue doctor/inspection until startup blockers are resolved",
          next_execution_mode_command: doctor_result.doctor_command_summary,
          operator_action: :keep_inspecting,
          operator_action_command: doctor_result.doctor_command_summary
        ).freeze unless doctor_result.startup_readiness == :ready

        scheduler_result = @execute_until_idle.call(project_context: project_context, max_steps: max_steps)
        Result.new(
          status: :completed,
          doctor_result: doctor_result,
          migration_result: migration_result,
          scheduler_result: scheduler_result,
          next_execution_mode: :scheduler_loop,
          next_execution_mode_reason: "runtime canary completed with a ready runtime; continue scheduler loop for ongoing runnable processing",
          next_execution_mode_command: doctor_result.runtime_command_summary,
          operator_action: :start_continuous_processing,
          operator_action_command: doctor_result.runtime_command_summary
        ).freeze
      end

      private

      def doctor_runtime
        A3::Application::DoctorRuntimeEnvironment.new(runtime_package: @runtime_package).call
      end

      def migrate_scheduler_store
        A3::Application::MigrateSchedulerStore.new(runtime_package: @runtime_package).call
      end
    end
  end
end
