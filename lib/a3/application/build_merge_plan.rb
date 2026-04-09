# frozen_string_literal: true

module A3
  module Application
    class BuildMergePlan
      Result = Struct.new(:task, :run, :merge_plan, keyword_init: true)

      def initialize(task_repository:, run_repository:, merge_planning_policy: A3::Domain::MergePlanningPolicy.new)
        @task_repository = task_repository
        @run_repository = run_repository
        @merge_planning_policy = merge_planning_policy
      end

      def call(task_ref:, run_ref:, project_context:)
        task = @task_repository.fetch(task_ref)
        run = @run_repository.fetch(run_ref)
        merge_plan = @merge_planning_policy.build(
          task: task,
          run: run,
          merge_config: project_context.merge_config_for(task: task, phase: run.phase)
        )

        Result.new(task: task, run: run, merge_plan: merge_plan)
      end
    end
  end
end
