# frozen_string_literal: true

require "fcntl"
require "json"
require "optparse"
require "pathname"
require "tempfile"
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

  WorkerRunRecord = Struct.new(
    :task_ref, :task_id, :team, :phase, :state, :started_at, :heartbeat_at, :updated_at_epoch_ms,
    :last_output_at, :last_output_line, :current_command, :result_path, :stdout_log_path, :stderr_log_path,
    :raw_stdout_log_path, :raw_stderr_log_path, :cwd, :detail, :log_scope,
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
        "detail" => detail
      }
    end
  end

  WorkerRunStore = Struct.new(:runs, keyword_init: true) do
    def to_h
      ordered = runs.keys.sort_by { |ref| [runs.fetch(ref).updated_at_epoch_ms, ref] }.reverse
      { "runs" => ordered.each_with_object({}) { |ref, acc| acc[ref] = runs.fetch(ref).to_h } }
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

  def load_worker_run_store(path)
    store_path = Pathname(path)
    return WorkerRunStore.new(runs: {}) unless store_path.exist?

    payload = JSON.parse(store_path.read)
    raw_runs = payload["runs"] || {}
    raise "worker run store must contain runs object" unless raw_runs.is_a?(Hash)

    runs = {}
    raw_runs.each do |key, raw_record|
      raise "worker run entry must be an object: #{key}" unless raw_record.is_a?(Hash)
      updated_at = raw_record["updated_at_epoch_ms"]
      raise "worker run updated_at_epoch_ms must be an integer: #{key}" unless updated_at.is_a?(Integer)
      task_id = raw_record["task_id"]
      runs[key.to_s] = WorkerRunRecord.new(
        task_ref: raw_record["task_ref"].to_s.strip,
        task_id: task_id.nil? ? nil : Integer(task_id),
        team: raw_record["team"].to_s.strip,
        phase: raw_record["phase"].to_s.strip.empty? ? nil : raw_record["phase"].to_s.strip,
        log_scope: raw_record.fetch("log_scope", "worker").to_s.strip.empty? ? "worker" : raw_record.fetch("log_scope", "worker").to_s.strip,
        state: raw_record["state"].to_s.strip,
        started_at: raw_record["started_at"].to_s.strip,
        heartbeat_at: raw_record["heartbeat_at"].to_s.strip,
        updated_at_epoch_ms: updated_at,
        last_output_at: raw_record["last_output_at"].to_s.strip.empty? ? nil : raw_record["last_output_at"].to_s.strip,
        last_output_line: raw_record["last_output_line"].to_s.strip.empty? ? nil : raw_record["last_output_line"].to_s.strip,
        current_command: raw_record["current_command"].to_s.strip.empty? ? nil : raw_record["current_command"].to_s.strip,
        result_path: raw_record["result_path"].to_s.strip.empty? ? nil : raw_record["result_path"].to_s.strip,
        stdout_log_path: raw_record["stdout_log_path"].to_s.strip.empty? ? nil : raw_record["stdout_log_path"].to_s.strip,
        stderr_log_path: raw_record["stderr_log_path"].to_s.strip.empty? ? nil : raw_record["stderr_log_path"].to_s.strip,
        raw_stdout_log_path: raw_record["raw_stdout_log_path"].to_s.strip.empty? ? nil : raw_record["raw_stdout_log_path"].to_s.strip,
        raw_stderr_log_path: raw_record["raw_stderr_log_path"].to_s.strip.empty? ? nil : raw_record["raw_stderr_log_path"].to_s.strip,
        cwd: raw_record["cwd"].to_s.strip.empty? ? nil : raw_record["cwd"].to_s.strip,
        detail: raw_record["detail"].to_s.strip.empty? ? nil : raw_record["detail"].to_s.strip
      )
    end
    WorkerRunStore.new(runs: runs)
  end

  def save_worker_run_store(path, store)
    exclusive_file_lock(path) do
      atomic_write_text(path, JSON.pretty_generate(store.to_h) + "\n")
    end
    store
  end

  def describe_worker_runs(path)
    load_worker_run_store(path).runs.values.sort_by { |item| [item.updated_at_epoch_ms, item.task_ref] }.reverse
  end

  def live_scheduler_processes(project, patterns: nil)
    result = IO.popen(["ps", "-axo", "command="], &:read)
    matches = []
    effective_patterns = Array(patterns).map(&:to_s).map(&:strip).reject(&:empty?)
    if effective_patterns.empty?
      effective_patterns = [
        "scripts/a3/#{project}_scheduler_launcher.rb --run-shot",
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
    return if stale_active_runs.empty?

    store = load_worker_run_store(worker_runs_file)
    runs = store.runs.dup
    changed = false
    stale_active_runs.each do |item|
      runs.each do |record_key, record|
        next unless record.task_ref == item.fetch("task_ref")
        next if TERMINAL_WORKER_RUN_STATES.include?(record.state)

        detail_suffix = "reconciled_stale_run(reason=#{item.fetch('reason')})"
        detail = record.detail.to_s
        detail = "#{detail}; #{detail_suffix}".sub(/\A; /, "").strip unless detail.include?(detail_suffix)
        runs[record_key] = WorkerRunRecord.new(**record.to_h.transform_keys(&:to_sym), detail: detail, state: "failed")
        changed = true
      end
    end
    save_worker_run_store(worker_runs_file, WorkerRunStore.new(runs: runs)) if changed
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
    parser.banner = "usage: reconcile.rb --project NAME --active-runs-file FILE --worker-runs-file FILE [options]"
    parser.on("--project VALUE") { |value| options[:project] = value }
    parser.on("--active-runs-file VALUE") { |value| options[:active_runs_file] = value }
    parser.on("--worker-runs-file VALUE") { |value| options[:worker_runs_file] = value }
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
    worker_runs_file = Pathname(options.fetch(:worker_runs_file))
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
