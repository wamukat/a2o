# frozen_string_literal: true

require "securerandom"
require "shellwords"

module A3
  module Infra
    class AgentDecompositionCommandRunner
      CommandStatus = Struct.new(:success?, :exitstatus)

      def initialize(control_plane_client:, runtime_profile:, task_ref:, stage:, project_key: A3::Domain::ProjectIdentity.current, timeout_seconds: 1800, poll_interval_seconds: 1.0, job_id_generator: -> { SecureRandom.uuid }, sleeper: ->(seconds) { sleep(seconds) }, monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, env: {}, agent_environment: nil)
        @control_plane_client = control_plane_client
        @runtime_profile = runtime_profile.to_s
        @task_ref = task_ref.to_s
        @stage = stage.to_s
        @project_key = A3::Domain::ProjectIdentity.normalize(project_key) || A3::Domain::ProjectIdentity.current
        @timeout_seconds = Integer(timeout_seconds)
        @poll_interval_seconds = Float(poll_interval_seconds)
        @job_id_generator = job_id_generator
        @sleeper = sleeper
        @monotonic_clock = monotonic_clock
        @env = env.transform_keys(&:to_s).transform_values(&:to_s).freeze
        @agent_environment = agent_environment
      end

      def call(command, chdir:, env:)
        request = build_request(command: command, chdir: chdir, env: env)
        @control_plane_client.enqueue(request)
        completed = wait_for_completion(request.job_id)
        return failure_tuple("agent decomposition job #{completed.state}", nil) unless completed.result

        result = completed.result
        diagnostics = result.worker_protocol_result&.fetch("diagnostics", nil)
        stdout = diagnostics.is_a?(Hash) ? diagnostics.fetch("stdout", "").to_s : ""
        stderr = diagnostics.is_a?(Hash) ? diagnostics.fetch("stderr", "").to_s : ""
        [stdout, stderr, CommandStatus.new(result.succeeded?, result.exit_code)]
      rescue StandardError => e
        failure_tuple("#{e.class}: #{e.message}", nil)
      end

      private

      def build_request(command:, chdir:, env:)
        job_id = @job_id_generator.call.to_s
        A3::Domain::AgentJobRequest.new(
          job_id: job_id,
          project_key: @project_key,
          task_ref: @task_ref,
          run_ref: "decomposition:#{@stage}:#{@task_ref}:#{job_id}",
          phase: :verification,
          runtime_profile: @runtime_profile,
          source_descriptor: A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: @task_ref, ref: "decomposition-#{@stage}"),
          workspace_request: nil,
          agent_environment: @agent_environment,
          working_dir: chdir.to_s,
          command: "sh",
          args: ["-lc", Shellwords.join(Array(command).map(&:to_s))],
          env: @env.merge(env.transform_keys(&:to_s).transform_values(&:to_s)),
          timeout_seconds: @timeout_seconds,
          artifact_rules: [],
          worker_protocol_request: {
            "command_intent" => "decomposition_#{@stage}",
            "task_ref" => @task_ref,
            "stage" => @stage
          }
        )
      end

      def wait_for_completion(job_id)
        deadline = @monotonic_clock.call + @timeout_seconds
        loop do
          record = @control_plane_client.fetch(job_id)
          return record if record.state == :completed || record.state == :stale

          break if @monotonic_clock.call >= deadline

          @sleeper.call([@poll_interval_seconds, deadline - @monotonic_clock.call].min)
        end
        raise "agent decomposition job wait timed out job_id=#{job_id}"
      end

      def failure_tuple(message, exitstatus)
        ["", message.to_s, CommandStatus.new(false, exitstatus)]
      end
    end
  end
end
