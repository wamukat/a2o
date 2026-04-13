# frozen_string_literal: true

require "json"
require "open3"
require "optparse"
require "pathname"
require "tempfile"
require "time"
require "a3/operator/cleanup"
require "a3/operator/diagnostics"
require "a3/operator/reconcile"
require "a3/operator/rerun_quarantine"
require "a3/operator/rerun_readiness"

module A3RootUtilityLauncher
  PrepareRuntimeConfigFailed = Class.new(StandardError)
  ROOT_DIR = Pathname(ENV.fetch("A3_ROOT_DIR", Dir.pwd)).expand_path.freeze
  CONFIG_DIR = ROOT_DIR.join(ENV.fetch("A3_ROOT_CONFIG_DIR", "scripts/a3/config")).freeze
  RUNTIME_CONFIG = ROOT_DIR.join(ENV.fetch("A3_ROOT_RUNTIME_CONFIG_PATH", ".work/a3/config/runtime.json")).freeze
  PREPARE_RUNTIME_CONFIG_SCRIPT = ROOT_DIR.join(ENV.fetch("A3_ROOT_PREPARE_RUNTIME_CONFIG_SCRIPT", "scripts/a3/prepare_runtime_config.rb")).freeze
  LEGACY_A3ENGINE_DISABLED_MESSAGE = ENV.fetch("A3_ROOT_LEGACY_DISABLED_MESSAGE", "Legacy A3Engine commands are disabled. Use canonical A3 root entrypoints or root local utility commands only.").freeze
  LEGACY_A3ENGINE_COMMANDS = %w[
    validate-manifest
    describe-project
    describe-context
    validate-launcher-config
    describe-launch-plan
    describe-scheduler-package
    materialize-scheduler-package
    execute-promotion
    apply-kanban-mutations
    plan-run-once
    execute-worker-action
    apply-worker-result
    execute-run-once
    dispatch-run-once
    describe-active-run
    watch-worker-log
    watch-summary
    load-task-snapshots
    plan-run
    describe-phase-plan
    evaluate-preflight
    execute-phase
  ].freeze
  COMMANDS = %w[
    pause-scheduler
    resume-scheduler
    describe-scheduler-control
    describe-state
    watch
    doctor-env
    cleanup
    reconcile-active-runs
    quarantine-rerun-artifacts
    check-rerun-readiness
  ].freeze

  module_function

  def project_manifest_path(project)
    CONFIG_DIR.join(project, "project.json")
  end

  def project_launcher_config_path(project)
    CONFIG_DIR.join(project, "launcher.json")
  end

  def resolve_kanban_project(project, manifest_override = nil)
    manifest_path = manifest_override ? Pathname(manifest_override) : project_manifest_path(project)
    payload = JSON.parse(manifest_path.read)
    project_payload = payload["project"]
    raise "project manifest is missing project metadata: #{manifest_path}" unless project_payload.is_a?(Hash)

    kanban_project = project_payload["kanban_project"]
    if !kanban_project.is_a?(String) || kanban_project.strip.empty?
      raise "project manifest is missing project.kanban_project: #{manifest_path}"
    end

    kanban_project.strip
  end

  def resolve_active_runs_file(project:, active_runs_file: nil)
    active_runs_file ? Pathname(active_runs_file) : ROOT_DIR.join(".work", "a3", "state", project, "active-runs.json")
  end

  def resolve_worker_runs_file(project:, worker_runs_file: nil)
    worker_runs_file ? Pathname(worker_runs_file) : ROOT_DIR.join(".work", "a3", "state", project, "worker-runs.json")
  end

  def resolve_scheduler_pause_file(project)
    ROOT_DIR.join(".work", "a3", "state", project, "scheduler-paused.json")
  end

  def reconcile_live_process_patterns(project)
    injected_patterns = ENV.fetch("A3_ROOT_RECONCILE_LIVE_PROCESS_PATTERN", "").split(File::PATH_SEPARATOR)
    (injected_patterns + ["#{project}-kanban-scheduler-auto"]).map(&:strip).reject(&:empty?)
  end

  def scheduler_pause_payload(project, reason: "")
    pause_file = resolve_scheduler_pause_file(project)
    payload = {
      "project" => project,
      "paused" => pause_file.exist?,
      "pause_file" => pause_file.to_s
    }
    if pause_file.exist?
      begin
        data = JSON.parse(pause_file.read)
      rescue JSON::ParserError
        data = {}
      end
      if data.is_a?(Hash)
        %w[paused_at reason].each do |key|
          value = data.fetch(key, "").to_s.strip
          payload[key] = value unless value.empty?
        end
      end
    elsif !reason.strip.empty?
      payload["reason"] = reason.strip
    end
    payload
  end

  def atomic_write_scheduler_pause_file(path, payload)
    path.dirname.mkpath
    temp = Tempfile.new([".#{path.basename}.", ".tmp"], path.dirname.to_s, mode: File::RDWR)
    begin
      temp.write(JSON.pretty_generate(payload) + "\n")
      temp.flush
      temp.fsync
      File.rename(temp.path, path)
    ensure
      temp.close!
    end
  end

  def remove_scheduler_pause_file(path)
    return unless path.exist?

    path.delete
    dir = File.open(path.dirname)
    dir.fsync
  rescue SystemCallError
    nil
  ensure
    dir&.close
  end

  def pause_scheduler(project, reason: "")
    pause_file = resolve_scheduler_pause_file(project)
    atomic_write_scheduler_pause_file(
      pause_file,
      {
        "paused_at" => Time.now.utc.iso8601,
        "reason" => reason.strip
      }
    )
    puts JSON.pretty_generate(scheduler_pause_payload(project))
    0
  end

  def resume_scheduler(project)
    pause_file = resolve_scheduler_pause_file(project)
    remove_scheduler_pause_file(pause_file)
    puts JSON.pretty_generate(scheduler_pause_payload(project))
    0
  end

  def guard_legacy_command_argv(argv)
    return if argv.empty?
    raise SystemExit, LEGACY_A3ENGINE_DISABLED_MESSAGE if LEGACY_A3ENGINE_COMMANDS.include?(argv.first)
  end

  def run_diagnostics_command(argv)
    A3Diagnostics.main(argv)
  end

  def run_reconcile_command(argv)
    A3Reconcile.main(argv)
  end

  def run_prepare_runtime_config
    _stdout, stderr, status = Open3.capture3("ruby", PREPARE_RUNTIME_CONFIG_SCRIPT.to_s, chdir: ROOT_DIR.to_s)
    warn stderr unless stderr.empty?
    status.exitstatus || 1
  end

  def resolve_launcher_config(project:, command:, launcher_config: nil)
    runtime_config_projects = ENV.fetch("A3_ROOT_RUNTIME_CONFIG_PROJECTS", "").split(",").map(&:strip).reject(&:empty?)
    if launcher_config.nil? && runtime_config_projects.include?(project) && %w[doctor-env reconcile-active-runs cleanup].include?(command)
      rc = run_prepare_runtime_config
      raise PrepareRuntimeConfigFailed, rc.to_s unless rc.zero?

      return RUNTIME_CONFIG
    end
    launcher_config ? Pathname(launcher_config) : project_launcher_config_path(project)
  end

  def help_text
    <<~TEXT
      Root utility launcher for A3 migration support.

      Commands:
        pause-scheduler
        resume-scheduler
        describe-scheduler-control
        describe-state
        watch
        doctor-env
        cleanup
        reconcile-active-runs
        quarantine-rerun-artifacts
        check-rerun-readiness
    TEXT
  end

  def parse_command(argv)
    raise SystemExit, help_text if argv.empty?
    raise SystemExit, help_text if %w[-h --help].include?(argv.first)

    command = argv.first
    raise SystemExit, "unknown command: #{command}" unless COMMANDS.include?(command)

    options = { "project" => ENV.fetch("A3_ROOT_DEFAULT_PROJECT", "default") }
    parser = OptionParser.new
    parser.on("--project PROJECT") { |value| options["project"] = value }

    case command
    when "pause-scheduler"
      options["reason"] = ""
      parser.on("--reason REASON") { |value| options["reason"] = value }
    when "describe-state"
      parser.on("--active-runs-file PATH") { |value| options["active_runs_file"] = value }
      parser.on("--worker-runs-file PATH") { |value| options["worker_runs_file"] = value }
    when "watch"
      options["interval"] = 2.0
      options["iterations"] = 0
      parser.on("--active-runs-file PATH") { |value| options["active_runs_file"] = value }
      parser.on("--worker-runs-file PATH") { |value| options["worker_runs_file"] = value }
      parser.on("--interval SECONDS", Float) { |value| options["interval"] = value }
      parser.on("--iterations COUNT", Integer) { |value| options["iterations"] = value }
    when "doctor-env"
      parser.on("--launcher-config PATH") { |value| options["launcher_config"] = value }
    when "cleanup"
      options.merge!(
        "done_ttl_hours" => 24,
        "blocked_ttl_hours" => 24,
        "result_ttl_hours" => 168,
        "log_ttl_hours" => 168,
        "quarantine_ttl_hours" => 168,
        "cache_ttl_hours" => 168,
        "build_output_ttl_hours" => 168,
        "max_quarantine_count" => nil,
        "max_result_count" => nil,
        "max_log_count" => nil,
        "max_quarantine_bytes" => nil,
        "max_result_bytes" => nil,
        "max_log_bytes" => nil,
        "max_cache_bytes" => nil,
        "max_build_output_bytes" => nil,
        "apply" => false
      )
      parser.on("--manifest PATH") { |value| options["manifest"] = value }
      parser.on("--active-runs-file PATH") { |value| options["active_runs_file"] = value }
      parser.on("--worker-runs-file PATH") { |value| options["worker_runs_file"] = value }
      parser.on("--launcher-config PATH") { |value| options["launcher_config"] = value }
      parser.on("--done-ttl-hours HOURS", Integer) { |value| options["done_ttl_hours"] = value }
      parser.on("--blocked-ttl-hours HOURS", Integer) { |value| options["blocked_ttl_hours"] = value }
      parser.on("--result-ttl-hours HOURS", Integer) { |value| options["result_ttl_hours"] = value }
      parser.on("--log-ttl-hours HOURS", Integer) { |value| options["log_ttl_hours"] = value }
      parser.on("--quarantine-ttl-hours HOURS", Integer) { |value| options["quarantine_ttl_hours"] = value }
      parser.on("--cache-ttl-hours HOURS", Integer) { |value| options["cache_ttl_hours"] = value }
      parser.on("--build-output-ttl-hours HOURS", Integer) { |value| options["build_output_ttl_hours"] = value }
      parser.on("--max-quarantine-count COUNT", Integer) { |value| options["max_quarantine_count"] = value }
      parser.on("--max-result-count COUNT", Integer) { |value| options["max_result_count"] = value }
      parser.on("--max-log-count COUNT", Integer) { |value| options["max_log_count"] = value }
      parser.on("--max-quarantine-bytes BYTES", Integer) { |value| options["max_quarantine_bytes"] = value }
      parser.on("--max-result-bytes BYTES", Integer) { |value| options["max_result_bytes"] = value }
      parser.on("--max-log-bytes BYTES", Integer) { |value| options["max_log_bytes"] = value }
      parser.on("--max-cache-bytes BYTES", Integer) { |value| options["max_cache_bytes"] = value }
      parser.on("--max-build-output-bytes BYTES", Integer) { |value| options["max_build_output_bytes"] = value }
      parser.on("--apply") { options["apply"] = true }
    when "reconcile-active-runs"
      options["apply"] = false
      parser.on("--active-runs-file PATH") { |value| options["active_runs_file"] = value }
      parser.on("--worker-runs-file PATH") { |value| options["worker_runs_file"] = value }
      parser.on("--launcher-config PATH") { |value| options["launcher_config"] = value }
      parser.on("--status STATUS") { |value| options["status"] = value }
      parser.on("--apply") { options["apply"] = true }
    when "quarantine-rerun-artifacts"
      options["path"] = []
      parser.on("--task-ref TASK_REF") { |value| options["task_ref"] = value }
      parser.on("--path PATH") { |value| options["path"] << value }
    when "check-rerun-readiness"
      options["allow_blocked_label"] = false
      parser.on("--task-ref TASK_REF") { |value| options["task_ref"] = value }
      parser.on("--allow-blocked-label") { options["allow_blocked_label"] = true }
    end

    parser.parse!(argv.drop(1))
    [command, options]
  end

  def main(argv = ARGV)
    actual_argv = Array(argv).dup
    guard_legacy_command_argv(actual_argv)
    command, options = parse_command(actual_argv)

    case command
    when "pause-scheduler"
      pause_scheduler(options.fetch("project"), reason: options.fetch("reason"))
    when "resume-scheduler"
      resume_scheduler(options.fetch("project"))
    when "describe-scheduler-control"
      puts JSON.pretty_generate(scheduler_pause_payload(options.fetch("project")))
      0
    when "describe-state"
      run_diagnostics_command(
        [
          "describe-state",
          "--project",
          options.fetch("project"),
          "--root-dir",
          ROOT_DIR.to_s,
          "--active-runs-file",
          resolve_active_runs_file(project: options.fetch("project"), active_runs_file: options["active_runs_file"]).to_s,
          "--worker-runs-file",
          resolve_worker_runs_file(project: options.fetch("project"), worker_runs_file: options["worker_runs_file"]).to_s
        ]
      )
    when "watch"
      run_diagnostics_command(
        [
          "watch",
          "--project",
          options.fetch("project"),
          "--root-dir",
          ROOT_DIR.to_s,
          "--active-runs-file",
          resolve_active_runs_file(project: options.fetch("project"), active_runs_file: options["active_runs_file"]).to_s,
          "--worker-runs-file",
          resolve_worker_runs_file(project: options.fetch("project"), worker_runs_file: options["worker_runs_file"]).to_s,
          "--interval",
          options.fetch("interval").to_s,
          "--iterations",
          options.fetch("iterations").to_s
        ]
      )
    when "cleanup"
      cleanup_command = [
        "--project",
        options.fetch("project"),
        "--kanban-project",
        resolve_kanban_project(options.fetch("project"), options["manifest"]),
        "--root-dir",
        ROOT_DIR.to_s,
        "--active-runs-file",
        resolve_active_runs_file(project: options.fetch("project"), active_runs_file: options["active_runs_file"]).to_s,
        "--worker-runs-file",
        resolve_worker_runs_file(project: options.fetch("project"), worker_runs_file: options["worker_runs_file"]).to_s,
        "--launcher-config",
        resolve_launcher_config(
          project: options.fetch("project"),
          command: command,
          launcher_config: options["launcher_config"]
        ).to_s,
        "--done-ttl-hours",
        options.fetch("done_ttl_hours").to_s,
        "--blocked-ttl-hours",
        options.fetch("blocked_ttl_hours").to_s,
        "--result-ttl-hours",
        options.fetch("result_ttl_hours").to_s,
        "--log-ttl-hours",
        options.fetch("log_ttl_hours").to_s,
        "--quarantine-ttl-hours",
        options.fetch("quarantine_ttl_hours").to_s,
        "--cache-ttl-hours",
        options.fetch("cache_ttl_hours").to_s,
        "--build-output-ttl-hours",
        options.fetch("build_output_ttl_hours").to_s
      ]
      if options["max_quarantine_count"]
        cleanup_command.concat(["--max-quarantine-count", options.fetch("max_quarantine_count").to_s])
      end
      if options["max_result_count"]
        cleanup_command.concat(["--max-result-count", options.fetch("max_result_count").to_s])
      end
      if options["max_log_count"]
        cleanup_command.concat(["--max-log-count", options.fetch("max_log_count").to_s])
      end
      if options["max_quarantine_bytes"]
        cleanup_command.concat(["--max-quarantine-bytes", options.fetch("max_quarantine_bytes").to_s])
      end
      if options["max_result_bytes"]
        cleanup_command.concat(["--max-result-bytes", options.fetch("max_result_bytes").to_s])
      end
      if options["max_log_bytes"]
        cleanup_command.concat(["--max-log-bytes", options.fetch("max_log_bytes").to_s])
      end
      if options["max_cache_bytes"]
        cleanup_command.concat(["--max-cache-bytes", options.fetch("max_cache_bytes").to_s])
      end
      if options["max_build_output_bytes"]
        cleanup_command.concat(["--max-build-output-bytes", options.fetch("max_build_output_bytes").to_s])
      end
      cleanup_command << "--apply" if options.fetch("apply")
      A3Cleanup.main(cleanup_command)
    when "reconcile-active-runs"
      reconcile_command = [
        "--project",
        options.fetch("project"),
        "--active-runs-file",
        resolve_active_runs_file(project: options.fetch("project"), active_runs_file: options["active_runs_file"]).to_s,
        "--worker-runs-file",
        resolve_worker_runs_file(project: options.fetch("project"), worker_runs_file: options["worker_runs_file"]).to_s
      ]
      reconcile_live_process_patterns(options.fetch("project")).each do |pattern|
        reconcile_command.concat(["--live-process-pattern", pattern])
      end
      if options["status"]
        reconcile_command.concat(
          [
            "--launcher-config",
            resolve_launcher_config(
              project: options.fetch("project"),
              command: command,
              launcher_config: options["launcher_config"]
            ).to_s,
            "--status",
            options.fetch("status")
          ]
        )
      end
      reconcile_command << "--apply" if options.fetch("apply")
      run_reconcile_command(reconcile_command)
    when "quarantine-rerun-artifacts"
      quarantine_command = [
        "--project",
        options.fetch("project"),
        "--root-dir",
        ROOT_DIR.to_s,
        "--task-ref",
        options.fetch("task_ref")
      ]
      options.fetch("path").each do |path|
        quarantine_command.concat(["--path", path])
      end
      A3RerunQuarantine.main(quarantine_command)
    when "check-rerun-readiness"
      readiness_command = [
        "--project",
        options.fetch("project"),
        "--root-dir",
        ROOT_DIR.to_s,
        "--task-ref",
        options.fetch("task_ref"),
        "--active-runs-file",
        resolve_active_runs_file(project: options.fetch("project")).to_s,
        "--worker-runs-file",
        resolve_worker_runs_file(project: options.fetch("project")).to_s,
        "--kanban-project",
        resolve_kanban_project(options.fetch("project"))
      ]
      readiness_command << "--allow-blocked-label" if options.fetch("allow_blocked_label")
      A3RerunReadiness.main(readiness_command, default_kanban_working_dir: ROOT_DIR)
    when "doctor-env"
      run_diagnostics_command(
        [
          "doctor-env",
          "--launcher-config",
          resolve_launcher_config(
            project: options.fetch("project"),
            command: command,
            launcher_config: options["launcher_config"]
          ).to_s
        ]
      )
    else
      1
    end
  rescue SystemExit => e
    if e.message == help_text
      puts e.message
      return 0
    end
    warn e.message
    1
  rescue PrepareRuntimeConfigFailed => e
    e.message.to_i
  end
end

exit(A3RootUtilityLauncher.main) if $PROGRAM_NAME == __FILE__
