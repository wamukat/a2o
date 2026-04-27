# frozen_string_literal: true

require "fcntl"
require "json"
require "optparse"
require "pathname"
require "tempfile"
require "a3/operator/activity_evidence"
require "a3/operator/diagnostics"

module A3Reconcile
  TERMINAL_WORKER_RUN_STATES = A3Diagnostics::TERMINAL_WORKER_RUN_STATES

  ActiveRunState = Struct.new(:task_refs, keyword_init: true) do
    def normalized
      self.class.new(task_refs: task_refs.to_a.map(&:to_s).uniq.sort)
    end

    def to_h
      { "active_task_refs" => normalized.task_refs }
    end
  end

  StaleActiveRun = Struct.new(:task_ref, :task_id, :reason, :latest_state, keyword_init: true) do
    def to_h
      {
        "task_ref" => task_ref,
        "task_id" => task_id,
        "reason" => reason,
        "latest_state" => latest_state
      }
    end
  end

  module_function

  def lock_path(path)
    target = Pathname(path)
    target.sub_ext("#{target.extname}.lock")
  end

  def exclusive_file_lock(path)
    target = lock_path(path)
    target.dirname.mkpath
    target.open(File::RDWR | File::CREAT, 0o644) do |handle|
      handle.flock(File::LOCK_EX)
      yield
    ensure
      handle.flock(File::LOCK_UN)
    end
  end

  def atomic_write_text(path, content)
    target = Pathname(path)
    target.dirname.mkpath
    Tempfile.create([".#{target.basename}", ".tmp"], target.dirname.to_s) do |handle|
      handle.write(content)
      handle.flush
      handle.fsync
      File.rename(handle.path, target.to_s)
    end
    target
  end

  def load_active_run_state(path)
    store_path = Pathname(path)
    return ActiveRunState.new(task_refs: []) unless store_path.exist?

    payload = JSON.parse(store_path.read)
    raw_refs = payload["active_task_refs"] || []
    raise "active run store must contain active_task_refs list" unless raw_refs.is_a?(Array)

    ActiveRunState.new(task_refs: raw_refs.map(&:to_s).reject(&:empty?)).normalized
  end

  def save_active_run_state(path, state)
    normalized = state.normalized
    exclusive_file_lock(path) do
      atomic_write_text(path, JSON.pretty_generate(normalized.to_h) + "\n")
    end
    normalized
  end

  def describe_worker_runs(path)
    A3::Operator::ActivityEvidence.describe_activity(activity_file: A3::Operator::ActivityEvidence.agent_jobs_path_from(worker_runs_file: path))
  end

  def live_scheduler_processes(project, patterns: nil)
    result = IO.popen(["ps", "-axo", "command="], &:read)
    matches = []
    effective_patterns = Array(patterns).map(&:to_s).map(&:strip).reject(&:empty?)
    if effective_patterns.empty?
      effective_patterns = [
        "#{project}-kanban-scheduler-auto"
      ]
    end
    result.to_s.each_line do |raw_line|
      line = raw_line.strip
      next if line.empty?

      if effective_patterns.any? { |pattern| line.include?(pattern) }
        matches << line
      end
    end
    matches
  end

  def inspect_stale_active_runs(project:, active_runs_file:, worker_runs_file:, task_ref: nil, live_process_patterns: nil)
    active_state = load_active_run_state(active_runs_file)
    latest_runs = {}
    describe_worker_runs(worker_runs_file).each do |record|
      latest_runs[record.task_ref] ||= record
    end
    live_processes = live_scheduler_processes(project, patterns: live_process_patterns)
    stale_runs = []
    candidate_refs = active_state.task_refs.to_set
    latest_runs.each do |ref, latest|
      candidate_refs << ref unless TERMINAL_WORKER_RUN_STATES.include?(latest.state)
    end
    candidate_refs = Set[task_ref] if task_ref

    candidate_refs.to_a.sort.each do |candidate_ref|
      latest = latest_runs[candidate_ref]
      if latest.nil?
        stale_runs << StaleActiveRun.new(task_ref: candidate_ref, task_id: nil, reason: "missing_worker_run", latest_state: nil)
        next
      end
      if TERMINAL_WORKER_RUN_STATES.include?(latest.state)
        stale_runs << StaleActiveRun.new(task_ref: candidate_ref, task_id: latest.task_id, reason: "latest_run_terminal", latest_state: latest.state)
        next
      end
      unless A3Diagnostics.effectively_live_worker_run?(latest)
        stale_runs << StaleActiveRun.new(task_ref: candidate_ref, task_id: latest.task_id, reason: "stale_worker_run", latest_state: latest.state)
        next
      end
      if live_processes.empty?
        stale_runs << StaleActiveRun.new(task_ref: candidate_ref, task_id: latest.task_id, reason: "no_live_process", latest_state: latest.state)
      end
    end
    stale_refs = stale_runs.map(&:task_ref).to_set
    remaining_refs = active_state.task_refs.reject { |ref| stale_refs.include?(ref) }
    {
      "project" => project,
      "active_runs_file" => active_runs_file.to_s,
      "worker_runs_file" => worker_runs_file.to_s,
      "live_processes" => live_processes,
      "active_refs_before" => active_state.task_refs,
      "stale_active_runs" => stale_runs.map(&:to_h),
      "active_refs_after" => remaining_refs
    }
  end

  def mark_stale_worker_runs(worker_runs_file, stale_active_runs)
    nil
  end

  def apply_stale_active_run_reconciliation(project:, active_runs_file:, worker_runs_file:, task_ref: nil, live_process_patterns: nil)
    payload = inspect_stale_active_runs(project: project, active_runs_file: active_runs_file, worker_runs_file: worker_runs_file, task_ref: task_ref, live_process_patterns: live_process_patterns)
    save_active_run_state(active_runs_file, ActiveRunState.new(task_refs: payload.fetch("active_refs_after")))
    mark_stale_worker_runs(worker_runs_file, payload.fetch("stale_active_runs"))
    payload.merge("applied" => true)
  end

  def apply_status_reset(launcher_config:, task_ref:, task_id:, status:)
    config = A3Diagnostics.load_launcher_config(launcher_config)
    kanban = config["kanban"]
    raise SystemExit, "launcher config does not define kanban backend." if kanban.nil?

    env = A3Diagnostics.build_runtime_env(config.fetch("runtime_env", {}), config.fetch("shell", {}))
    command, working_directory = build_status_reset_command(
      kanban: kanban,
      task_ref: task_ref,
      task_id: task_id,
      status: status
    )
    ok = system(env, *command, chdir: working_directory || Dir.pwd)
    exit_code = $CHILD_STATUS ? ($CHILD_STATUS.exitstatus || (ok ? 0 : 1)) : (ok ? 0 : 1)
    raise SystemExit, exit_code unless exit_code.zero?
  end

  def build_status_reset_command(kanban:, task_ref:, task_id:, status:)
    backend = String(kanban["backend"]).strip
    case backend
    when "", "subprocess-cli"
      command = Array(kanban["command_argv"]) + ["task-transition"]
      if task_id
        command += ["--task-id", task_id.to_s]
      else
        command += ["--task", task_ref]
      end
      command += ["--status", status]
      [command, kanban["working_directory"]]
    else
      raise SystemExit, "unsupported kanban backend for reconcile status reset: #{backend}"
    end
  end

  def parse_args(argv)
    options = {}
    parser = OptionParser.new
    parser.banner = "usage: reconcile.rb --project NAME --active-runs-file FILE --agent-jobs-file FILE [options]"
    parser.on("--project VALUE") { |value| options[:project] = value }
    parser.on("--active-runs-file VALUE") { |value| options[:active_runs_file] = value }
    parser.on("--agent-jobs-file VALUE") { |value| options[:agent_jobs_file] = value }
    parser.on("--worker-runs-file VALUE") do
      raise OptionParser::InvalidOption,
            "removed option --worker-runs-file; migration_required=true replacement=--agent-jobs-file"
    end
    parser.on("--launcher-config VALUE") { |value| options[:launcher_config] = value }
    parser.on("--status VALUE") { |value| options[:status] = value }
    parser.on("--task-ref VALUE") { |value| options[:task_ref] = value }
    parser.on("--live-process-pattern VALUE") { |value| (options[:live_process_patterns] ||= []) << value }
    parser.on("--apply") { options[:apply] = true }
    parser.parse!(argv)
    options
  end

  def main(argv = ARGV, out: $stdout)
    options = parse_args(argv.dup)
    active_runs_file = Pathname(options.fetch(:active_runs_file))
    worker_runs_file = Pathname(options.fetch(:agent_jobs_file)).dirname.join("worker-runs.json")
    payload =
      if options[:apply]
        result = apply_stale_active_run_reconciliation(
          project: options.fetch(:project),
          active_runs_file: active_runs_file,
          worker_runs_file: worker_runs_file,
          task_ref: options[:task_ref],
          live_process_patterns: options[:live_process_patterns]
        )
        if options[:status]
          raise SystemExit, "--launcher-config is required when --status is provided." unless options[:launcher_config]
          result.fetch("stale_active_runs").each do |item|
            apply_status_reset(
              launcher_config: Pathname(options.fetch(:launcher_config)),
              task_ref: item.fetch("task_ref"),
              task_id: item["task_id"],
              status: options.fetch(:status)
            )
          end
        end
        result
      else
        inspect_stale_active_runs(
          project: options.fetch(:project),
          active_runs_file: active_runs_file,
          worker_runs_file: worker_runs_file,
          task_ref: options[:task_ref],
          live_process_patterns: options[:live_process_patterns]
        ).merge("applied" => false)
      end
    out.puts(JSON.pretty_generate(payload))
    0
  rescue KeyError, OptionParser::ParseError => e
    warn(e.message)
    1
  end
end

if $PROGRAM_NAME == __FILE__
  exit(A3Reconcile.main)
end
