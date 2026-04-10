# frozen_string_literal: true

module A3
  module Application
    class RegisterStartedRun
      Result = Struct.new(:task, :run, keyword_init: true)

      def initialize(task_repository:, run_repository:, publish_external_task_status: nil, publish_external_task_activity: nil)
        @task_repository = task_repository
        @run_repository = run_repository
        @publish_external_task_status = publish_external_task_status
        @publish_external_task_activity = publish_external_task_activity
      end

      def call(task_ref:, run:)
        task = @task_repository.fetch(task_ref)
        @run_repository.save(run)
        updated_task = task.start_run(run.ref, phase: run.phase)
        @task_repository.save(updated_task)
        @publish_external_task_status&.publish(
          task_ref: updated_task.ref,
          external_task_id: updated_task.external_task_id,
          status: updated_task.status,
          task_kind: updated_task.kind
        )
        @publish_external_task_activity&.publish(
          task_ref: updated_task.ref,
          external_task_id: updated_task.external_task_id,
          body: started_run_comment(run: run)
        )

        Result.new(task: updated_task, run: run)
      end

      private

      def started_run_comment(run:)
        [
          "A3-v2 実行開始: #{run.phase}",
          "run_ref: #{run.ref}",
          "source_ref: #{run.source_descriptor.ref}"
        ].join("\n")
      end
    end
  end
end
