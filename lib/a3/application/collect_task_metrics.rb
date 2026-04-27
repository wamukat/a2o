# frozen_string_literal: true

require "json"
require "time"
require_relative "build_worker_task_packet"

module A3
  module Application
    class CollectTaskMetrics
      Result = Struct.new(:collected, :record, :error, keyword_init: true) do
        def collected?
          !!collected
        end
      end

      def initialize(command_runner:, task_metrics_repository:, task_packet_builder: A3::Application::BuildWorkerTaskPacket.new(external_task_source: A3::Infra::NullExternalTaskSource.new), worker_protocol: A3::Infra::WorkerProtocol.new, clock: -> { Time.now.utc })
        @command_runner = command_runner
        @task_metrics_repository = task_metrics_repository
        @task_packet_builder = task_packet_builder
        @worker_protocol = worker_protocol
        @clock = clock
      end

      def call(task:, run:, runtime:, workspace:)
        return Result.new(collected: false) if runtime.metrics_collection_commands.empty?

        command_context = command_request_context(
          task: task,
          run: run,
          runtime: runtime,
          workspace: workspace
        )
        execution = @command_runner.run(
          runtime.metrics_collection_commands,
          workspace: workspace,
          env: command_context.fetch(:env),
          task: task,
          run: run,
          command_intent: :metrics_collection,
          worker_protocol_request: command_context.fetch(:request)
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

      def command_request_context(task:, run:, runtime:, workspace:)
        task_packet = @task_packet_builder.call(task: task)
        request = @worker_protocol.request_form(
          skill: nil,
          workspace: workspace,
          task: task,
          run: run,
          phase_runtime: runtime,
          task_packet: task_packet,
          command_intent: :metrics_collection
        )
        @worker_protocol.write_request(
          skill: nil,
          workspace: workspace,
          task: task,
          run: run,
          phase_runtime: runtime,
          task_packet: task_packet,
          command_intent: :metrics_collection
        )

        {
          env: @worker_protocol.env_for(workspace),
          request: request
        }
      end

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
