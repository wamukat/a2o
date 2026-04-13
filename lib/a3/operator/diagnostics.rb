# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"
require "set"
require "time"

module A3Diagnostics
  TERMINAL_WORKER_RUN_STATES = Set.new(%w[completed failed timed_out blocked kanban_apply_failed blocked_task_failure blocked_refresh_failure launch_failed needs_commit_retry needs_handoff_retry needs_rework_retry no_op_terminal]).freeze
  DISPLAY_PHASE_ALIASES = { "integration_judgment" => "merge" }.freeze
  STANDARD_PATH_DIRS = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].freeze

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

  module_function

  def split_path_entries(raw_path)
    return [] if raw_path.nil? || raw_path.empty?

    raw_path.split(File::PATH_SEPARATOR).reject(&:empty?)
  end

  def version_key(path)
    path.basename.to_s.split(".").map { |part| Integer(part) }
  rescue ArgumentError
    [0]
  end

  def volta_path_entries(env)
    volta_home = env["VOLTA_HOME"]
    return [] if volta_home.to_s.empty?

    root = Pathname(volta_home)
    candidates = []
    node_root = root.join("tools", "image", "node")
    if node_root.directory?
      node_bins = node_root.children.select { |path| path.join("bin").directory? }.map { |path| path.join("bin") }.sort_by { |path| version_key(path) }.reverse
      node_bins.each do |node_bin|
        entry = node_bin.to_s
        candidates << entry unless candidates.include?(entry)
      end
    end
    candidates
  end

  def executor_vendor_rg_candidates(env)
    home = env["AI_CLI_HOME"]
    candidates = []
    candidates << Pathname(home).join("vendor", "ripgrep", "rg") if home
    user_home = env["HOME"] || Dir.home
    candidates << Pathname(user_home).join(".ai-cli", "vendor", "ripgrep", "rg")
    candidates
  end

  def display_phase_name(phase)
    return nil if phase.nil?

    DISPLAY_PHASE_ALIASES.fetch(phase, phase)
  end

  def parse_heartbeat_timestamp(value)
    parsed = Time.iso8601(value)
    parsed.utc
  rescue ArgumentError
    nil
  end

  def effectively_live_worker_run?(record, stale_after_seconds: 120)
    return false if TERMINAL_WORKER_RUN_STATES.include?(record.state)

    heartbeat_at = parse_heartbeat_timestamp(record.heartbeat_at)
    return true if heartbeat_at.nil?

    (Time.now.utc - heartbeat_at) <= stale_after_seconds
  end

  def describe_worker_runs(path)
    store_path = Pathname(path)
    return [] unless store_path.exist?

    payload = JSON.parse(store_path.read)
    runs_payload = payload["runs"] || {}
    raise "worker run store runs must be an object" unless runs_payload.is_a?(Hash)

    records = runs_payload.values.map do |raw_record|
      raise "worker run entry must be an object" unless raw_record.is_a?(Hash)

      updated_at = raw_record["updated_at_epoch_ms"]
      raise "worker run updated_at_epoch_ms must be an integer" unless updated_at.is_a?(Integer)

      task_id = raw_record["task_id"]
      WorkerRunRecord.new(
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
    records.sort_by { |item| [item.updated_at_epoch_ms, item.task_ref] }.reverse
  end

  def normalize_env_value(value)
    normalized = value.strip
    if normalized.length >= 2 && normalized[0] == normalized[-1] && ["'", '"'].include?(normalized[0])
      normalized[1...-1]
    else
      normalized
    end
  end

  def parse_env_file(path)
    payload = {}
    Pathname(path).read.each_line do |raw_line|
      line = raw_line.strip
      next if line.empty? || line.start_with?("#")

      line = line.delete_prefix("export ").strip if line.start_with?("export ")
      raise "env file has invalid line: #{path}" unless line.include?("=")

      key, value = line.split("=", 2)
      normalized_key = key.strip
      raise "env file has invalid key: #{path}" if normalized_key.empty?

      payload[normalized_key] = normalize_env_value(value)
    end
    payload
  end

  def load_launcher_config(path)
    payload = JSON.parse(Pathname(path).read)
    raise "launcher config root must be an object" unless payload.is_a?(Hash)

    payload
  end

  def build_runtime_env(runtime_env, shell, env: ENV.to_h)
    source_env = shell.fetch("inherit_env", true) ? env.dup : {}
    Array(shell["env_files"]).each { |env_file| source_env.update(parse_env_file(env_file.to_s)) }
    (shell["env_overrides"] || {}).each { |key, value| source_env[key.to_s] = value.to_s }
    path_entries = []
    (Array(runtime_env["path_entries"]) + volta_path_entries(source_env) + split_path_entries(source_env["PATH"]) + STANDARD_PATH_DIRS).each do |entry|
      next if entry.to_s.empty? || path_entries.include?(entry)
      path_entries << entry
    end
    source_env["PATH"] = path_entries.join(File::PATH_SEPARATOR)
    Array(runtime_env["required_bins"]).each do |required_bin|
      resolved = find_executable(required_bin.to_s, source_env["PATH"])
      if resolved.nil? && required_bin.to_s == "rg" && runtime_env["allow_executor_vendor_rg_fallback"]
        executor_vendor_rg_candidates(source_env).each do |candidate|
          if candidate.file? && File.executable?(candidate)
            resolved = candidate.to_s
            break
          end
        end
      end
      next if resolved.nil?

      resolved_dir = Pathname(resolved).dirname.to_s
      path_entries.unshift(resolved_dir) unless path_entries.include?(resolved_dir)
    end
    source_env["PATH"] = path_entries.join(File::PATH_SEPARATOR)
    source_env
  end

  def find_executable(name, path)
    split_path_entries(path).each do |entry|
      candidate = Pathname(entry).join(name)
      return candidate.to_s if candidate.file? && File.executable?(candidate)
    end
    nil
  end

  def inspect_runtime_env(runtime_env, shell, env: ENV.to_h)
    built_env = build_runtime_env(runtime_env, shell, env: env)
    resolved_bins = {}
    missing_bins = []
    allow_vendor_fallback = !!runtime_env["allow_executor_vendor_rg_fallback"]
    Array(runtime_env["required_bins"]).each do |required_bin|
      resolved = find_executable(required_bin.to_s, built_env["PATH"])
      if resolved.nil? && required_bin.to_s == "rg" && allow_vendor_fallback
        executor_vendor_rg_candidates(built_env).each do |candidate|
          if candidate.file? && File.executable?(candidate)
            resolved = candidate.to_s
            break
          end
        end
      end
      if resolved.nil?
        missing_bins << required_bin.to_s
      else
        resolved_bins[required_bin.to_s] = resolved
      end
    end
    {
      "path" => built_env.fetch("PATH", ""),
      "resolved_bins" => resolved_bins,
      "missing_bins" => missing_bins
    }
  end

  def project_record_state(record)
    projected = record.dup
    state = projected["state"].to_s.strip
    internal_phase = projected["phase"].to_s.strip
    internal_phase = nil if internal_phase.empty?
    projected["phase"] = display_phase_name(internal_phase)
    projected["internal_phase"] = internal_phase if internal_phase && projected["phase"] != internal_phase
    projected["state"] = "launch_started" if ["started", "materializing_workspace"].include?(state)
    projected
  end

  def selected_pending_refs(active_refs, runs, raw_records)
    selected_from_runs = runs.select { |item| item["state"].to_s.strip == "selected" }.map { |item| item["task_ref"].to_s.strip }.to_set
    started_refs = raw_records.reject { |record| record.state.to_s.strip == "selected" }.map { |record| record.task_ref.to_s.strip }.to_set
    ((active_refs.to_set | selected_from_runs) - started_refs).reject(&:empty?).to_a.sort
  end

  def load_json(path, default)
    json = JSON.parse(Pathname(path).read)
    [json, nil]
  rescue Errno::ENOENT
    [default, nil]
  rescue StandardError => e
    [default, "#{Pathname(path).basename}: #{e}"]
  end

  def active_refs(path)
    payload, error = load_json(path, { "active_task_refs" => [] })
    return [[], error || "#{Pathname(path).basename}: root payload must be an object"] unless payload.is_a?(Hash)
    raw_refs = payload["active_task_refs"] || []
    return [[], error || "#{Pathname(path).basename}: active_task_refs must be an array"] unless raw_refs.is_a?(Array)
    [raw_refs.map(&:to_s).select { |ref| !ref.strip.empty? }, error]
  end

  def worker_runs(path)
    [describe_worker_runs(path), nil]
  rescue StandardError => e
    [[], "#{Pathname(path).basename}: #{e}"]
  end

  def scheduler_paths(root_dir, project)
    scheduler_dir = Pathname(root_dir).join(".work", "a3", "scheduler", project)
    files = []
    if scheduler_dir.exist?
      scheduler_dir.children.sort.each do |path|
        files << {
          "path" => path.to_s,
          "exists" => path.exist?,
          "size" => path.exist? ? path.size : 0
        }
      end
    end
    { "directory" => scheduler_dir.to_s, "files" => files }
  end

  def latest_results(root_dir, project, limit: 5)
    result_dir = Pathname(root_dir).join(".work", "a3", "results", project)
    return [] unless result_dir.exist?

    items = result_dir.glob("*.json").select(&:file?).sort_by { |path| path.mtime }.reverse
    items.take(limit).map do |path|
      entry = { "path" => path.to_s, "mtime" => path.mtime.to_f, "size" => path.size }
      begin
        payload = JSON.parse(path.read)
      rescue StandardError
        next entry
      end
      preflight = payload.is_a?(Hash) ? payload["preflight"] : nil
      if preflight.is_a?(Hash)
        source_selection = []
        preflight_failures = []
        Array(preflight["repos"]).each do |repo|
          next unless repo.is_a?(Hash)
          if repo["source_selection"].is_a?(Hash)
            source_selection << { "repo_id" => repo["repo_id"] }.merge(repo["source_selection"])
          end
          Array(repo["guards"]).each do |guard|
            next unless guard.is_a?(Hash)
            next if guard["ok"] == true
            preflight_failures << {
              "repo_id" => repo["repo_id"],
              "kind" => guard["kind"],
              "message" => guard["message"],
              "actual" => guard["actual"]
            }
          end
        end
        entry["preflight_source_selection"] = source_selection unless source_selection.empty?
        entry["preflight_failures"] = preflight_failures unless preflight_failures.empty?
      end
      entry
    end
  end

  def describe_state(project:, root_dir:, active_runs_file:, worker_runs_file:)
    active_refs_value, active_error = active_refs(active_runs_file)
    raw_records, worker_error = worker_runs(worker_runs_file)
    runs = raw_records.map { |item| project_record_state(item.to_h) }
    running = raw_records.select { |record| record.state.to_s != "selected" && effectively_live_worker_run?(record) }.map { |record| project_record_state(record.to_h) }
    unavailable = []
    unavailable << active_error if active_error
    unavailable << worker_error if worker_error
    {
      "project" => project,
      "active_runs_file" => active_runs_file.to_s,
      "worker_runs_file" => worker_runs_file.to_s,
      "active_refs" => active_refs_value,
      "selected_pending_refs" => selected_pending_refs(active_refs_value, runs, raw_records),
      "state_unavailable" => unavailable,
      "running_runs" => running,
      "recent_runs" => runs.take(5),
      "scheduler" => scheduler_paths(root_dir, project),
      "latest_results" => latest_results(root_dir, project)
    }
  end

  def doctor_env(launcher_config_path:)
    config = load_launcher_config(launcher_config_path)
    shell = (config["shell"] || {}).dup
    runtime_env = (config["runtime_env"] || {}).dup
    status = inspect_runtime_env(runtime_env, shell, env: ENV.to_h)
    env_files = Array(shell["env_files"]).map { |path| { "path" => path, "exists" => Pathname(path).exist? } }
    {
      "launcher_config" => launcher_config_path.to_s,
      "scheduler" => config["scheduler"],
      "kanban" => config["kanban"],
      "shell" => shell.merge("env_files" => env_files),
      "runtime_env" => status
    }
  end

  def parse_args(argv)
    options = {}
    parser = OptionParser.new
    parser.banner = "usage: diagnostics.rb <describe-state|watch|doctor-env> [options]"
    parser.order!(argv)
    options[:command] = argv.shift
    case options[:command]
    when "describe-state", "watch"
      parser.on("--project VALUE") { |value| options[:project] = value }
      parser.on("--root-dir VALUE") { |value| options[:root_dir] = value }
      parser.on("--active-runs-file VALUE") { |value| options[:active_runs_file] = value }
      parser.on("--worker-runs-file VALUE") { |value| options[:worker_runs_file] = value }
      parser.on("--interval VALUE", Float) { |value| options[:interval] = value }
      parser.on("--iterations VALUE", Integer) { |value| options[:iterations] = value }
    when "doctor-env"
      parser.on("--launcher-config VALUE") { |value| options[:launcher_config] = value }
    end
    parser.parse!(argv)
    options
  end

  def main(argv = ARGV, out: $stdout, sleeper: Kernel)
    options = parse_args(argv.dup)
    case options[:command]
    when "describe-state"
      out.puts(JSON.pretty_generate(describe_state(project: options.fetch(:project), root_dir: Pathname(options.fetch(:root_dir)), active_runs_file: Pathname(options.fetch(:active_runs_file)), worker_runs_file: Pathname(options.fetch(:worker_runs_file)))))
      0
    when "watch"
      count = 0
      loop do
        out.puts("\n---\n") if count.positive?
        out.puts(JSON.pretty_generate(describe_state(project: options.fetch(:project), root_dir: Pathname(options.fetch(:root_dir)), active_runs_file: Pathname(options.fetch(:active_runs_file)), worker_runs_file: Pathname(options.fetch(:worker_runs_file)))))
        count += 1
        return 0 if options[:iterations].to_i.positive? && count >= options[:iterations]
        sleeper.sleep(options.fetch(:interval, 2.0))
      end
    when "doctor-env"
      out.puts(JSON.pretty_generate(doctor_env(launcher_config_path: Pathname(options.fetch(:launcher_config)))))
      0
    else
      1
    end
  rescue KeyError, OptionParser::ParseError => e
    warn(e.message)
    1
  end
end

if $PROGRAM_NAME == __FILE__
  exit(A3Diagnostics.main)
end
