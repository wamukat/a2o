# frozen_string_literal: true

require "a3/bootstrap/runtime_services_builder/support_group_builder"
require "a3/bootstrap/runtime_services_builder/scheduling_group_builder"
require "a3/bootstrap/runtime_services_builder/execution_group_builder"

module A3
  module Bootstrap
    class RuntimeServicesBuilder
      def self.build(repositories:, run_id_generator:, command_runner:, merge_runner:, worker_gateway:, storage_dir:, repo_sources:, external_task_source: A3::Infra::NullExternalTaskSource.new, external_task_status_publisher: A3::Infra::NullExternalTaskStatusPublisher.new, external_task_activity_publisher: A3::Infra::NullExternalTaskActivityPublisher.new, external_follow_up_child_writer: nil)
        new(
          repositories: repositories,
          run_id_generator: run_id_generator,
          command_runner: command_runner,
          merge_runner: merge_runner,
          worker_gateway: worker_gateway,
          storage_dir: storage_dir,
          repo_sources: repo_sources,
          external_task_source: external_task_source,
          external_task_status_publisher: external_task_status_publisher,
          external_task_activity_publisher: external_task_activity_publisher,
          external_follow_up_child_writer: external_follow_up_child_writer
        ).build
      end

      def initialize(repositories:, run_id_generator:, command_runner:, merge_runner:, worker_gateway:, storage_dir:, repo_sources:, external_task_source: A3::Infra::NullExternalTaskSource.new, external_task_status_publisher: A3::Infra::NullExternalTaskStatusPublisher.new, external_task_activity_publisher: A3::Infra::NullExternalTaskActivityPublisher.new, external_follow_up_child_writer: nil)
        @repositories = repositories
        @run_id_generator = run_id_generator
        @command_runner = command_runner
        @merge_runner = merge_runner
        @worker_gateway = worker_gateway
        @storage_dir = storage_dir
        @repo_sources = repo_sources
        @external_task_source = external_task_source
        @external_task_status_publisher = external_task_status_publisher
        @external_task_activity_publisher = external_task_activity_publisher
        @external_follow_up_child_writer = external_follow_up_child_writer
      end

      def build
        support_group
          .merge(scheduling_group)
          .merge(execution_group)
          .freeze
      end

      private

      def support_group
        @support_group ||= A3::Bootstrap::RuntimeServicesBuilder::SupportGroupBuilder.build(
          repositories: @repositories,
          run_id_generator: @run_id_generator,
          storage_dir: @storage_dir,
          repo_sources: @repo_sources,
          external_task_source: @external_task_source,
          external_task_status_publisher: @external_task_status_publisher,
          external_task_activity_publisher: @external_task_activity_publisher,
          external_follow_up_child_writer: @external_follow_up_child_writer
        )
      end

      def scheduling_group
        @scheduling_group ||= A3::Bootstrap::RuntimeServicesBuilder::SchedulingGroupBuilder.build(
          repositories: @repositories,
          support_group: support_group,
          external_task_source: @external_task_source
        )
      end

      def execution_group
        @execution_group ||= A3::Bootstrap::RuntimeServicesBuilder::ExecutionGroupBuilder.build(
          repositories: @repositories,
          support_group: support_group,
          command_runner: @command_runner,
          merge_runner: @merge_runner,
          worker_gateway: @worker_gateway,
          external_task_source: @external_task_source
        )
      end
    end
  end
end
