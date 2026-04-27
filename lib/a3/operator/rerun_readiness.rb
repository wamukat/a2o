# frozen_string_literal: true

require "json"
require "open3"
require "optparse"
require "pathname"
require "set"
require "a3/operator/activity_evidence"
require "a3/operator/rerun_workspace_support"

module A3
  module Operator
    module RerunReadiness
      TERMINAL_AGENT_JOB_STATES = ActivityEvidence::TERMINAL_STATES
      ReadinessCheck = Struct.new(:name, :ok, :blocking, :detail, keyword_init: true) do
        def to_h
          {
            "name" => name,
            "ok" => ok,
            "blocking" => blocking,
            "detail" => detail
          }
        end
      end

      module_function

      def load_active_run_state(path)
        store_path = Pathname(path)
        return [] unless store_path.exist?

        payload = JSON.parse(store_path.read)
        raw_refs = payload.fetch("active_task_refs", [])
        raise "active run store must contain a list of task refs" unless raw_refs.is_a?(Array)

        raw_refs.map { |item| item.to_s.strip }.reject(&:empty?).uniq.sort
      end

      def load_legacy_worker_run_activity(path)
        ActivityEvidence.latest_by_task_ref(activity_file: ActivityEvidence.agent_jobs_path_from(worker_runs_file: path)).transform_values(&:to_h)
      end

      def load_agent_job_store(path)
        ActivityEvidence.latest_by_task_ref(activity_file: path).transform_values(&:to_h)
      end

      def latest_agent_job(worker_runs_file: nil, agent_jobs_file: nil, task_ref:)
        store = agent_jobs_file ? load_agent_job_store(agent_jobs_file) : load_legacy_worker_run_activity(worker_runs_file)
        store[task_ref]
      end

      def resolve_task_id(task_ref:, worker_runs_file: nil, agent_jobs_file: nil)
        latest = latest_agent_job(worker_runs_file: worker_runs_file, agent_jobs_file: agent_jobs_file, task_ref: task_ref)
        latest && latest["task_id"]
      end

      def inspect_kanban_task(project:, task_id:, working_dir:)
        status = nil
        done = nil
        labels = []

        stdout, _stderr, command_status = Open3.capture3(
          "task",
          "kanban:api",
          "--",
          "task-get",
          "--project",
          project,
          "--task-id",
          task_id.to_s,
          chdir: Pathname(working_dir).to_s
        )
        return [nil, nil, []] unless command_status.success?

        payload = JSON.parse(stdout)
        if payload.is_a?(Hash)
          raw_status = payload["status"]
          status = raw_status.strip if raw_status.is_a?(String) && !raw_status.strip.empty?
          done = payload["done"] if payload["done"] == true || payload["done"] == false
        end

        label_stdout, = Open3.capture3(
          "task",
          "kanban:api",
          "--",
          "task-label-list",
          "--project",
          project,
          "--task-id",
          task_id.to_s,
          chdir: Pathname(working_dir).to_s
        )
        labels_payload = JSON.parse(label_stdout)
        if labels_payload.is_a?(Array)
          labels = labels_payload.filter_map do |item|
            next unless item.is_a?(Hash)

            title = item["title"].to_s.strip
            title.empty? ? nil : title
          end
        end
        [status, done, labels]
      rescue JSON::ParserError
        [status, done, labels]
      rescue StandardError => e
        raise e unless e.is_a?(Errno::ENOENT)

        [nil, nil, []]
      end

      def inspect_rerun_readiness(root_dir:, project:, task_ref:, active_runs_file:, worker_runs_file: nil, agent_jobs_file: nil, kanban_project: nil, kanban_working_dir: Dir.pwd, allow_blocked_label: false)
        issue_workspace = RerunWorkspaceSupport.compute_issue_workspace(root_dir: root_dir, project: project, task_ref: task_ref)
        active_refs = load_active_run_state(active_runs_file)
        latest = latest_agent_job(worker_runs_file: worker_runs_file, agent_jobs_file: agent_jobs_file, task_ref: task_ref)
        cleanup_paths = RerunWorkspaceSupport.collect_default_rerun_paths(issue_workspace: issue_workspace).map(&:to_s)
        broken_bridges = RerunWorkspaceSupport.top_level_broken_support_bridges(issue_workspace).map(&:to_s)

        task_status = nil
        task_done = nil
        label_titles = []
        task_id = resolve_task_id(task_ref: task_ref, worker_runs_file: worker_runs_file, agent_jobs_file: agent_jobs_file)
        if kanban_project && task_id
          task_status, task_done, label_titles = inspect_kanban_task(project: kanban_project, task_id: task_id, working_dir: kanban_working_dir)
        end

        checks = []
        checks << ReadinessCheck.new(
          name: "active_run_cleared",
          ok: !active_refs.include?(task_ref),
          blocking: true,
          detail: "task is not present in active-runs.json"
        )
        checks << ReadinessCheck.new(
          name: "latest_agent_job_terminal_or_absent",
          ok: latest.nil? || TERMINAL_AGENT_JOB_STATES.include?(latest["state"].to_s.strip),
          blocking: true,
          detail: "latest agent job is terminal or missing"
        )
        checks << ReadinessCheck.new(
          name: "broken_support_bridges_cleared",
          ok: broken_bridges.empty?,
          blocking: true,
          detail: "no broken top-level support bridge remains in issue workspace"
        )
        checks << ReadinessCheck.new(
          name: "rerun_cleanup_paths_cleared",
          ok: cleanup_paths.empty?,
          blocking: true,
          detail: "default rerun quarantine targets are already absent"
        )
        if kanban_project && task_id
          checks << ReadinessCheck.new(
            name: "task_not_done",
            ok: task_done != true,
            blocking: true,
            detail: "kanban task is not already Done"
          )
          blocked_present = label_titles.include?("blocked")
          checks << ReadinessCheck.new(
            name: "blocked_label_cleared",
            ok: !blocked_present || allow_blocked_label,
            blocking: !allow_blocked_label,
            detail: "kanban blocked label is cleared before rerun"
          )
        end

        annotated_checks = checks.map do |item|
          detail = item.detail
          if item.name == "active_run_cleared" && !item.ok
            detail = "task is still active: #{task_ref}"
          elsif item.name == "latest_agent_job_terminal_or_absent" && !item.ok && latest
            detail = "latest agent job is non-terminal: #{latest['state']}"
          elsif item.name == "broken_support_bridges_cleared" && !item.ok
            detail = "broken top-level support bridges remain: #{broken_bridges.join(', ')}"
          elsif item.name == "rerun_cleanup_paths_cleared" && !item.ok
            detail = "rerun quarantine still required for: #{cleanup_paths.join(', ')}"
          elsif item.name == "task_not_done" && !item.ok
            detail = "kanban task is already done: status=#{task_status || 'unknown'}"
          elsif item.name == "blocked_label_cleared" && label_titles.include?("blocked")
            detail =
              if allow_blocked_label
                "kanban blocked label is present but explicit rerun may proceed"
              else
                "kanban blocked label is still present"
              end
          end
          ReadinessCheck.new(name: item.name, ok: item.ok, blocking: item.blocking, detail: detail)
        end

        ready = annotated_checks.all? { |item| item.ok || !item.blocking }
        {
          "project" => project,
          "task_ref" => task_ref,
          "issue_workspace" => issue_workspace.to_s,
          "ready" => ready,
          "latest_agent_job" => latest,
          "cleanup_paths" => cleanup_paths,
          "checks" => annotated_checks.map(&:to_h),
          "task_status" => task_status,
          "task_done" => task_done,
          "label_titles" => label_titles
        }
      end

      def parse_args(argv)
        options = {
          kanban_project: nil,
          kanban_working_dir: nil,
          allow_blocked_label: false
        }

        parser = OptionParser.new
        parser.banner = "usage: rerun_readiness.rb --project NAME --root-dir DIR --task-ref REF --active-runs-file FILE --agent-jobs-file FILE [options]"
        parser.on("--project VALUE") { |value| options[:project] = value }
        parser.on("--root-dir VALUE") { |value| options[:root_dir] = value }
        parser.on("--task-ref VALUE") { |value| options[:task_ref] = value }
        parser.on("--active-runs-file VALUE") { |value| options[:active_runs_file] = value }
        parser.on("--agent-jobs-file VALUE") { |value| options[:agent_jobs_file] = value }
        parser.on("--worker-runs-file VALUE") do
          raise OptionParser::InvalidOption,
                "removed option --worker-runs-file; migration_required=true replacement=--agent-jobs-file"
        end
        parser.on("--kanban-project VALUE") { |value| options[:kanban_project] = value }
        parser.on("--kanban-working-dir VALUE") { |value| options[:kanban_working_dir] = value }
        parser.on("--allow-blocked-label") { options[:allow_blocked_label] = true }
        parser.parse!(argv)

        %i[project root_dir task_ref active_runs_file agent_jobs_file].each do |key|
          raise OptionParser::MissingArgument, "--#{key.to_s.tr('_', '-')}" if options[key].to_s.empty?
        end
        options
      end

      def main(argv = ARGV, out: $stdout, default_kanban_working_dir: Dir.pwd)
        options = parse_args(argv.dup)
        kanban_working_dir = options[:kanban_working_dir].to_s.strip.empty? ? default_kanban_working_dir : options[:kanban_working_dir]
        result = inspect_rerun_readiness(
          root_dir: options.fetch(:root_dir),
          project: options.fetch(:project),
          task_ref: options.fetch(:task_ref),
          active_runs_file: options.fetch(:active_runs_file),
          agent_jobs_file: Pathname(options.fetch(:agent_jobs_file)),
          kanban_project: options[:kanban_project].to_s.strip.empty? ? nil : options[:kanban_project].strip,
          kanban_working_dir: kanban_working_dir,
          allow_blocked_label: options.fetch(:allow_blocked_label)
        )
        out.puts(JSON.pretty_generate(result))
        result.fetch("ready") ? 0 : 2
      rescue OptionParser::ParseError => e
        warn(e.message)
        1
      end
    end
  end
end

A3RerunReadiness = A3::Operator::RerunReadiness unless Object.const_defined?(:A3RerunReadiness)
