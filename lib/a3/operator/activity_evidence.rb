# frozen_string_literal: true

require "json"
require "pathname"
require "set"
require "time"

module A3
  module Operator
    module ActivityEvidence
      TERMINAL_STATES = Set.new(%w[completed failed timed_out blocked kanban_apply_failed blocked_task_failure blocked_refresh_failure launch_failed needs_commit_retry needs_handoff_retry needs_rework_retry no_op_terminal]).freeze

      Record = Struct.new(
        :task_ref, :task_id, :team, :phase, :state, :started_at, :heartbeat_at, :updated_at_epoch_ms,
        :last_output_at, :last_output_line, :current_command, :result_path, :stdout_log_path, :stderr_log_path,
        :raw_stdout_log_path, :raw_stderr_log_path, :cwd, :detail, :log_scope, :job_id,
        keyword_init: true
      ) do
        def to_h
          {
            "task_ref" => task_ref,
            "task_id" => task_id,
            "team" => team,
            "phase" => phase,
            "log_scope" => log_scope,
            "state" => state,
            "started_at" => started_at,
            "heartbeat_at" => heartbeat_at,
            "updated_at_epoch_ms" => updated_at_epoch_ms,
            "last_output_at" => last_output_at,
            "last_output_line" => last_output_line,
            "current_command" => current_command,
            "result_path" => result_path,
            "stdout_log_path" => stdout_log_path,
            "stderr_log_path" => stderr_log_path,
            "raw_stdout_log_path" => raw_stdout_log_path,
            "raw_stderr_log_path" => raw_stderr_log_path,
            "cwd" => cwd,
            "detail" => detail,
            "job_id" => job_id
          }.compact
        end
      end

      module_function

      def agent_jobs_path_from(worker_runs_file:)
        Pathname(worker_runs_file).dirname.join("agent_jobs.json")
      end

      def legacy_state_diagnostic(worker_runs_file:)
        path = Pathname(worker_runs_file)
        return nil unless path.exist?

        "removed worker-runs.json state detected: #{path}; migration_required=true replacement=#{agent_jobs_path_from(worker_runs_file: path)}"
      end

      def parse_time(value)
        raw = value.to_s.strip
        return nil if raw.empty?

        Time.iso8601(raw).utc
      rescue ArgumentError
        nil
      end

      def epoch_ms(value)
        time = parse_time(value)
        time ? (time.to_f * 1000).to_i : 0
      end

      def task_id_from(task_ref)
        match = task_ref.to_s.match(/#(\d+)\z/)
        match && Integer(match[1])
      end

      def activity_state_for(agent_job_state, result)
        activity_state = result.is_a?(Hash) ? result["activity_state"].to_s.strip : ""
        return activity_state unless activity_state.empty?

        case agent_job_state.to_s.strip
        when "claimed"
          "running_command"
        when "completed"
          result_state = result.is_a?(Hash) ? result["status"].to_s.strip : ""
          result_state.empty? || result_state == "success" ? "completed" : result_state
        else
          agent_job_state.to_s.strip
        end
      end

      def describe_agent_jobs(path)
        store_path = Pathname(path)
        return [] unless store_path.exist?

        payload = JSON.parse(store_path.read)
        raise "agent job store root must be an object" unless payload.is_a?(Hash)

        payload.filter_map do |job_id, raw_record|
          raise "agent job entry must be an object: #{job_id}" unless raw_record.is_a?(Hash)

          request = raw_record["request"]
          raise "agent job request must be an object: #{job_id}" unless request.is_a?(Hash)

          task_ref = request["task_ref"].to_s.strip
          next if task_ref.empty?

          heartbeat_at = raw_record["heartbeat_at"].to_s.strip
          claimed_at = raw_record["claimed_at"].to_s.strip
          state = activity_state_for(raw_record["state"], raw_record["result"])
          updated_at = epoch_ms(heartbeat_at.empty? ? claimed_at : heartbeat_at)
          updated_at = epoch_ms(claimed_at) if updated_at.zero?
          Record.new(
            task_ref: task_ref,
            task_id: task_id_from(task_ref),
            team: request["phase"].to_s.strip,
            phase: request["phase"].to_s.strip.empty? ? nil : request["phase"].to_s.strip,
            state: state,
            started_at: claimed_at,
            heartbeat_at: heartbeat_at.empty? ? claimed_at : heartbeat_at,
            updated_at_epoch_ms: updated_at,
            current_command: [request["command"], *Array(request["args"])].compact.join(" ").strip,
            cwd: request["working_dir"].to_s.strip.empty? ? nil : request["working_dir"].to_s.strip,
            detail: "agent_job=#{job_id}",
            log_scope: "agent_job",
            job_id: job_id.to_s
          )
        end.sort_by { |item| [item.updated_at_epoch_ms, item.task_ref, item.job_id.to_s] }.reverse
      end

      def describe_activity(activity_file:)
        describe_agent_jobs(activity_file)
      end

      def latest_by_task_ref(activity_file:)
        describe_activity(activity_file: activity_file).each_with_object({}) do |record, memo|
          memo[record.task_ref] ||= record
        end
      end

      def effectively_live?(record, stale_after_seconds: 120)
        return false if TERMINAL_STATES.include?(record.state)

        heartbeat_at = parse_time(record.heartbeat_at)
        return true if heartbeat_at.nil?

        (Time.now.utc - heartbeat_at) <= stale_after_seconds
      end
    end
  end
end
