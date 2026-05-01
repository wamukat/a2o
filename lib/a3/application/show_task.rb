# frozen_string_literal: true

module A3
  module Application
    class ShowTask
      def initialize(task_repository:, run_repository: nil, task_claim_repository: nil)
        @task_repository = task_repository
        @run_repository = run_repository
        @task_claim_repository = task_claim_repository
      end

      def call(task_ref:)
        task = @task_repository.fetch(task_ref)
        A3::Domain::OperatorInspectionReadModel::TaskView.from_task(
          task: task,
          tasks: @task_repository.all,
          skill_feedback: latest_skill_feedback(task),
          clarification_request: latest_clarification_request(task),
          claim_ref: active_claim_for(task)&.claim_ref
        )
      end

      private

      def latest_skill_feedback(task)
        return [] unless @run_repository

        run = latest_run_for(task)
        return [] unless run

        run.phase_records.flat_map do |record|
          Array(record.execution_record&.skill_feedback)
        end
      rescue A3::Domain::RecordNotFound, NoMethodError
        []
      end

      def latest_clarification_request(task)
        return nil unless @run_repository

        latest_run_for(task)&.phase_records&.reverse_each do |record|
          request = record.execution_record&.clarification_request
          return request if request.is_a?(Hash)
        end
        nil
      rescue A3::Domain::RecordNotFound, NoMethodError
        nil
      end

      def latest_run_for(task)
        return @run_repository.fetch(task.current_run_ref) if task.current_run_ref

        @run_repository.all.select { |run| run.task_ref == task.ref }.last
      end

      def active_claim_for(task)
        return nil unless @task_claim_repository

        @task_claim_repository.active_claims.find { |claim| claim.task_ref == task.ref }
      end
    end
  end
end
