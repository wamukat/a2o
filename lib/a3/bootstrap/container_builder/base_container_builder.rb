# frozen_string_literal: true

module A3
  module Bootstrap
    class ContainerBuilder
      class BaseContainerBuilder
        def self.build(context:)
          new(context: context).build
        end

        def initialize(context:)
          @context = context
        end

        def build
          {
            storage_dir: @context.storage_dir,
            task_repository: @context.task_repository,
            run_repository: @context.run_repository,
            task_metrics_repository: @context.task_metrics_repository,
            scheduler_state_repository: @context.scheduler_state_repository,
            scheduler_cycle_repository: @context.scheduler_cycle_repository,
            build_scope_snapshot: @context.build_scope_snapshot,
            build_artifact_owner: @context.build_artifact_owner,
            plan_next_decomposition_task: @context.plan_next_decomposition_task,
            external_task_source: @context.external_task_source,
            external_task_status_publisher: @context.external_task_status_publisher,
            external_task_activity_publisher: @context.external_task_activity_publisher
          }.freeze
        end
      end
    end
  end
end
