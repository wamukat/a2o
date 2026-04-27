# frozen_string_literal: true

require "json"
require "time"

module A3
  module Application
    class CollectTaskMetrics
      Result = Struct.new(:collected, :record, :error, keyword_init: true) do
        def collected?
          !!collected
        end
      end

      def initialize(command_runner:, task_metrics_repository:, clock: -> { Time.now.utc })
        @command_runner = command_runner
        @task_metrics_repository = task_metrics_repository
        @clock = clock
      end

      def call(task:, run:, runtime:, workspace:)
        return Result.new(collected: false) if runtime.metrics_collection_commands.empty?

        execution = @command_runner.run(
          runtime.metrics_collection_commands,
          workspace: workspace,
          env: {},
          task: task,
          run: run,
          command_intent: :metrics_collection
        )
        return failure_result(execution.summary, execution.failing_command, execution.observed_state) unless execution.success?

        payload = parse_payload(execution.diagnostics.fetch("stdout", ""))
        record = A3::Domain::TaskMetricsRecord.from_project_metrics(
          task_ref: task.ref,
          parent_ref: task.parent_ref,
          timestamp: @clock.call.iso8601,
          payload: payload
        )
        @task_metrics_repository.save(record)
        Result.new(collected: true, record: record)
      rescue JSON::ParserError => error
        failure_result("metrics collection produced invalid JSON", "metrics_collection", error.message)
      rescue ArgumentError, KeyError => error
        failure_result("metrics collection produced invalid metrics payload", "metrics_collection", error.message)
      end

      private

      def parse_payload(stdout)
        JSON.parse(stdout.to_s)
      end

      def failure_result(summary, failing_command, observed_state)
        Result.new(
          collected: false,
          error: {
            "summary" => summary,
            "failing_command" => failing_command,
            "observed_state" => observed_state
          }
        )
      end
    end
  end
end
