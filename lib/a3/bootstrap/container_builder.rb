# frozen_string_literal: true

require "a3/bootstrap/container_builder/execution_group_builder"
require "a3/bootstrap/container_builder/base_container_builder"
require "a3/bootstrap/container_builder/assembly_context"
require "a3/bootstrap/container_builder/operator_group_builder"
require "a3/bootstrap/container_builder/scheduler_group_builder"
require "a3/bootstrap/container_builder/shared_services_builder"

module A3
  module Bootstrap
    class ContainerBuilder
      def self.build(repositories:, runtime_services:)
        new(
          repositories: repositories,
          runtime_services: runtime_services
        ).build
      end

      def initialize(repositories:, runtime_services:)
        @repositories = repositories
        @runtime_services = runtime_services
      end

      def build
        @context ||= A3::Bootstrap::ContainerBuilder::AssemblyContext.new(
          repositories: @repositories,
          runtime_services: @runtime_services
        )
        shared_services = A3::Bootstrap::ContainerBuilder::SharedServicesBuilder.build(
          context: context
        )

        A3::Bootstrap::ContainerBuilder::BaseContainerBuilder.build(
          context: context
        )
          .merge(operator_group(shared_services))
          .merge(scheduler_group(shared_services))
          .merge(execution_group(shared_services))
          .freeze
      end

      private

      def execution_group(shared_services)
        A3::Bootstrap::ContainerBuilder::ExecutionGroupBuilder.build(
          context: context,
          execute_next_runnable_task: shared_services.fetch(:execute_next_runnable_task),
          execute_until_idle: shared_services.fetch(:execute_until_idle),
          cleanup_terminal_task_workspaces: shared_services.fetch(:cleanup_terminal_task_workspaces),
          quarantine_terminal_task_workspaces: shared_services.fetch(:quarantine_terminal_task_workspaces)
        )
      end

      def operator_group(shared_services)
        A3::Bootstrap::ContainerBuilder::OperatorGroupBuilder.build(
          context: context,
          plan_persisted_rerun: shared_services.fetch(:plan_persisted_rerun)
        )
      end

      def scheduler_group(shared_services)
        A3::Bootstrap::ContainerBuilder::SchedulerGroupBuilder.build(
          context: context,
          execute_until_idle: shared_services.fetch(:execute_until_idle)
        )
      end

      def context
        @context
      end
    end
  end
end
