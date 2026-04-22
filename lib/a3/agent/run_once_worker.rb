# frozen_string_literal: true

require "digest"
require "securerandom"
require "time"

module A3
  module Agent
    class RunOnceWorker
      def initialize(agent_name:, control_plane_client:, command_executor: A3::Agent::LocalCommandExecutor.new, clock: -> { Time.now.utc })
        @agent_name = agent_name
        @control_plane_client = control_plane_client
        @command_executor = command_executor
        @clock = clock
      end

      def call
        request = @control_plane_client.claim_next(agent_name: @agent_name)
        return :idle unless request

        started_at = timestamp
        execution = @command_executor.call(request)
        finished_at = timestamp
        log_upload = upload_combined_log(request: request, content: execution.combined_log)
        artifact_uploads = [upload_execution_metadata(request: request, execution: execution, started_at: started_at, finished_at: finished_at)] + upload_rule_artifacts(request)
        result = A3::Domain::AgentJobResult.new(
          job_id: request.job_id,
          status: execution.status,
          exit_code: execution.exit_code,
          started_at: started_at,
          finished_at: finished_at,
          summary: summary_for(request: request, execution: execution),
          log_uploads: [log_upload],
          artifact_uploads: artifact_uploads,
          workspace_descriptor: workspace_descriptor_for(request),
          heartbeat: finished_at
        )
        @control_plane_client.submit_result(result)
        result
      end

      private

      def upload_combined_log(request:, content:)
        upload = upload_metadata(
          artifact_id: safe_artifact_id("#{request.job_id}-combined-log"),
          role: "combined-log",
          content: content,
          retention_class: "analysis",
          media_type: "text/plain"
        )
        @control_plane_client.upload_artifact(upload, content)
      end

      def upload_execution_metadata(request:, execution:, started_at:, finished_at:)
        started = Time.iso8601(started_at)
        finished = Time.iso8601(finished_at)
        content = JSON.pretty_generate(
          {
            "job_id" => request.job_id,
            "task_ref" => request.task_ref,
            "run_ref" => request.run_ref,
            "phase" => request.phase,
            "status" => execution.status.to_s,
            "exit_code" => execution.exit_code,
            "summary" => summary_for(request: request, execution: execution),
            "command" => request.command,
            "args" => request.args,
            "started_at" => started_at,
            "finished_at" => finished_at,
            "duration_seconds" => finished - started,
            "runtime_profile" => request.runtime_profile,
            "source" => {
              "workspace_kind" => request.source_descriptor.workspace_kind,
              "source_type" => request.source_descriptor.source_type,
              "ref" => request.source_descriptor.ref,
              "task_ref" => request.source_descriptor.task_ref
            }
          }
        ) + "\n"
        upload = upload_metadata(
          artifact_id: safe_artifact_id("#{request.job_id}-execution-metadata"),
          role: "execution-metadata",
          content: content,
          retention_class: "analysis",
          media_type: "application/json"
        )
        @control_plane_client.upload_artifact(upload, content)
      end

      def upload_rule_artifacts(request)
        request.artifact_rules.flat_map do |rule|
          Dir.glob(File.join(request.working_dir, rule.fetch("glob"))).sort.map do |path|
            content = File.binread(path)
            upload = upload_metadata(
              artifact_id: safe_artifact_id("#{request.job_id}-#{rule.fetch("role")}-#{File.basename(path)}-#{SecureRandom.hex(4)}"),
              role: rule.fetch("role"),
              content: content,
              retention_class: rule.fetch("retention_class", "evidence"),
              media_type: rule["media_type"]
            )
            @control_plane_client.upload_artifact(upload, content)
          end
        end
      end

      def upload_metadata(artifact_id:, role:, content:, retention_class:, media_type:)
        A3::Domain::AgentArtifactUpload.new(
          artifact_id: artifact_id,
          role: role,
          digest: "sha256:#{Digest::SHA256.hexdigest(content)}",
          byte_size: content.bytesize,
          retention_class: retention_class,
          media_type: media_type
        )
      end

      def workspace_descriptor_for(request)
        A3::Domain::AgentWorkspaceDescriptor.new(
          workspace_kind: request.source_descriptor.workspace_kind,
          runtime_profile: request.runtime_profile,
          workspace_id: safe_artifact_id("#{request.runtime_profile}-#{request.job_id}"),
          source_descriptor: request.source_descriptor,
          slot_descriptors: {
            "primary" => {
              "runtime_path" => File.expand_path(request.working_dir),
              "dirty" => nil
            }
          }
        )
      end

      def summary_for(request:, execution:)
        "#{request.command} #{request.args.join(" ")} #{execution.status}"
      end

      def safe_artifact_id(value)
        value.gsub(/[^A-Za-z0-9._:-]/, "-")
      end

      def timestamp
        @clock.call.iso8601
      end
    end
  end
end
