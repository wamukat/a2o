# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "set"
require "time"
require "find"

require "a3/operator/rerun_workspace_support"

module A3Cleanup
  NON_CLEANUP_STATUSES = Set.new(["In progress", "In review", "Inspection", "Merging"]).freeze
  NONTERMINAL_WORKER_STATES = Set.new(["started", "running", "running_command", "thinking", "writing_result"]).freeze
  DISPOSABLE_CACHE_TOP_LEVELS = Set.new(["m2-seed"]).freeze
  BUILD_OUTPUT_DIR_NAMES = Set.new(["target", "surefire-reports", "site"]).freeze

  CleanupCandidate = Struct.new(:kind, :path, :reason, :task_ref, keyword_init: true) do
    def to_h
      {
        "kind" => kind,
        "path" => path,
        "reason" => reason,
        "task_ref" => task_ref
      }
    end
  end

  module_function

  def task_log_slug(task_ref)
    String(task_ref).tr("#", "-")
  end

  def current_scheduler_storage_dir(root_dir:, project:)
    Pathname(root_dir).join(".work", "a3", "#{project}-kanban-scheduler-auto")
  end

  def canonical_project_ref(project)
    normalized = String(project).strip
    return project if normalized.empty?

    normalized.length <= 4 ? normalized.upcase : "#{normalized[0].upcase}#{normalized[1..]}"
  end

  def normalize_env_value(value)
    quote = nil
    chars = []
    value.strip.each_char do |char|
      break if quote.nil? && char == "#" && !chars.empty? && chars.last.match?(/\s/)

      if ["'", "\""].include?(char)
        quote = quote.nil? ? char : (quote == char ? nil : quote)
      end
      chars << char
    end
    normalized = chars.join.strip
    if normalized.length >= 2 && normalized[0] == normalized[-1] && ["'", "\""].include?(normalized[0])
      normalized[1..-2]
    else
      normalized
    end
  end

  def parse_env_file(root_dir:, env_file:)
    path = Pathname(env_file)
    path = Pathname(root_dir).join(path) unless path.absolute?
    content = path.read
    parsed = {}
    content.each_line.with_index(1) do |raw_line, lineno|
      line = raw_line.strip
      next if line.empty? || line.start_with?("#")

      line = line.delete_prefix("export ").strip if line.start_with?("export ")
      raise "env file has invalid line #{lineno}: #{path}" unless line.include?("=")

      key, raw_value = line.split("=", 2)
      key = key.strip
      raise "env file has invalid key at line #{lineno}: #{path}" if key.empty?

      parsed[key] = normalize_env_value(raw_value)
    end
    parsed
  rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
    raise "env file is not valid UTF-8: #{path}"
  rescue Errno::ENOENT, Errno::EACCES
    raise "env file could not be read: #{path}"
  end

  def build_kanban_env(root_dir:, launcher_config:)
    env = ENV.to_h.dup
    config = launcher_config && Pathname(launcher_config)
    return env if config.nil? || !config.exist?

    payload = JSON.parse(config.read)
    shell = payload["shell"] || {}
    Array(shell["env_files"]).each do |env_file|
      env.update(parse_env_file(root_dir: root_dir, env_file: env_file))
    end
    env.update((shell["env_overrides"] || {}).transform_keys(&:to_s).transform_values(&:to_s))
    env
  end

  def load_task_snapshots(root_dir:, project:, launcher_config: nil)
    stdout, stderr, status = Open3.capture3(
      build_kanban_env(root_dir: root_dir, launcher_config: launcher_config),
      "task",
      "kanban:api",
      "--",
      "task-snapshot-list",
      "--project",
      project,
      chdir: root_dir.to_s
    )
    raise(stderr.strip.empty? ? (stdout.strip.empty? ? "task-snapshot-list failed" : stdout.strip) : stderr.strip) unless status.success?

    JSON.parse(stdout)
  end

  def load_active_refs(active_runs_file:, worker_runs_file:)
    active_refs = Set.new
    active_path = Pathname(active_runs_file)
    worker_path = Pathname(worker_runs_file)
    if active_path.exist?
      payload = JSON.parse(active_path.read)
      Array(payload["active_task_refs"]).each do |ref|
        value = ref.to_s.strip
        active_refs << value unless value.empty?
      end
    end
    if worker_path.exist?
      payload = JSON.parse(worker_path.read)
      (payload["runs"] || {}).each_value do |item|
        next unless item.is_a?(Hash)

        state = item["state"].to_s
        task_ref = item["task_ref"].to_s.strip
        active_refs << task_ref if !task_ref.empty? && NONTERMINAL_WORKER_STATES.include?(state)
      end
    end
    active_refs
  end

  def collect_task_paths(root_dir:, project:, task_ref:)
    project_slug = project.downcase
    task_slug = A3RerunWorkspaceSupport.canonical_task_slug(task_ref)
    paths = []

    issue_path = Pathname(root_dir).join(".work", "a3", "issues", project_slug, task_slug)
    paths << issue_path if issue_path.exist?

    runtime_root = Pathname(root_dir).join(".work", "a3", "runtime")
    if runtime_root.exist?
      runtime_root.children.each do |phase_dir|
        runtime_path = phase_dir.join(project_slug, task_slug)
        paths << runtime_path if runtime_path.exist?
      end
    end

    results_root = Pathname(root_dir).join(".work", "a3", "results", project_slug)
    if results_root.exist?
      suffix = "-#{task_log_slug(task_ref)}.json"
      results_root.glob("*#{suffix}").sort.each { |path| paths << path }
    end

    logs_root = Pathname(root_dir).join(".work", "a3", "results", "logs", project_slug, task_log_slug(task_ref))
    paths << logs_root if logs_root.exist?
    paths
  end

  def task_ref_from_slug(project_ref:, slug:)
    prefix = "#{project_ref.downcase}-"
    normalized_slug = slug.to_s.downcase
    return nil unless normalized_slug.start_with?(prefix)

    index = slug.to_s[prefix.length..].to_s.strip
    return nil if index.empty?

    "#{project_ref}##{index}"
  end

  def task_ref_from_result_path(project_ref:, path:)
    name = path.basename.to_s
    marker = "-#{project_ref}-"
    lower_name = name.downcase
    lower_marker = marker.downcase
    return nil unless lower_name.include?(lower_marker) && name.end_with?(".json")

    index = name[(lower_name.rindex(lower_marker) + marker.length)..].delete_suffix(".json").strip
    return nil if index.empty?

    "#{project_ref}##{index}"
  end

  def task_ref_from_log_dir(project_ref:, path:)
    name = path.basename.to_s
    marker = "#{project_ref}-"
    return nil unless name.downcase.start_with?(marker.downcase)

    index = name[marker.length..].strip
    return nil if index.empty?

    "#{project_ref}##{index}"
  end

  def collect_orphan_paths(root_dir:, project:, task_project_ref: nil, known_task_refs:, active_refs:)
    project_slug = project.downcase
    ref_project = task_project_ref || canonical_project_ref(project)
    refs_to_keep = known_task_refs | active_refs
    paths = []

    issue_root = Pathname(root_dir).join(".work", "a3", "issues", project_slug)
    if issue_root.exist?
      issue_root.children.sort.each do |issue_path|
        task_ref = task_ref_from_slug(project_ref: ref_project, slug: issue_path.basename.to_s)
        paths << issue_path if task_ref && !refs_to_keep.include?(task_ref)
      end
    end

    runtime_root = Pathname(root_dir).join(".work", "a3", "runtime")
    if runtime_root.exist?
      runtime_root.children.sort.each do |phase_dir|
        project_root = phase_dir.join(project_slug)
        next unless project_root.exist?

        project_root.children.sort.each do |runtime_path|
          task_ref = task_ref_from_slug(project_ref: ref_project, slug: runtime_path.basename.to_s)
          paths << runtime_path if task_ref && !refs_to_keep.include?(task_ref)
        end
      end
    end

    results_root = Pathname(root_dir).join(".work", "a3", "results", project_slug)
    if results_root.exist?
      results_root.glob("*.json").sort.each do |result_file|
        task_ref = task_ref_from_result_path(project_ref: ref_project, path: result_file)
        paths << result_file if task_ref && !refs_to_keep.include?(task_ref)
      end
    end

    logs_root = Pathname(root_dir).join(".work", "a3", "results", "logs", project_slug)
    if logs_root.exist?
      logs_root.children.sort.each do |log_dir|
        task_ref = task_ref_from_log_dir(project_ref: ref_project, path: log_dir)
        paths << log_dir if task_ref && !refs_to_keep.include?(task_ref)
      end
    end

    paths
  end

  def classify_cleanup_path(root_dir:, path:)
    relative = Pathname(path).relative_path_from(Pathname(root_dir).join(".work", "a3"))
    parts = relative.each_filename.to_a
    return "other" if parts.empty?
    return "issue_workspace" if parts[0] == "issues"
    return "runtime_workspace" if parts[0] == "runtime"
    return "log_dir" if parts[0] == "results" && parts[1] == "logs"
    return "result_file" if parts[0] == "results"

    "other"
  rescue ArgumentError
    "other"
  end

  def classify_current_cleanup_path(root_dir:, project:, path:)
    storage_root = current_scheduler_storage_dir(root_dir: root_dir, project: project)
    relative = Pathname(path).relative_path_from(storage_root)
    parts = relative.each_filename.to_a
    return "other" if parts.empty?
    return "quarantine_workspace" if parts[0] == "quarantine"
    return "build_output_dir" if parts.include?("quarantine") && build_output_path_parts?(parts)
    return "workspace_root" if parts[0] == "workspaces"

    "other"
  rescue ArgumentError
    "other"
  end

  def build_output_path_parts?(parts)
    BUILD_OUTPUT_DIR_NAMES.any? { |name| parts.include?(name) } ||
      parts.each_cons(3).any? { |triple| triple == [".work", "m2", "repository"] }
  end

  def latest_mtime(paths)
    return nil if paths.empty?

    paths.map { |path| File.mtime(path).utc }.max
  end

  def build_snapshot_index(task_snapshots)
    task_snapshots.each_with_object({}) do |snapshot, index|
      ref = snapshot["ref"].to_s.strip
      next if ref.empty?

      index[ref] = snapshot
    end
  end

  def cleanup_eligible_task?(task_ref:, snapshots_by_ref:, active_refs:)
    return true if task_ref.nil? || task_ref.empty?
    return false if active_refs.include?(task_ref)

    snapshot = snapshots_by_ref[task_ref]
    return true if snapshot.nil?

    !NON_CLEANUP_STATUSES.include?(snapshot["status"].to_s)
  end

  def cleanup_reason_for_snapshot(snapshot:, active_refs:, artifact_mtime:, now:, done_ttl_hours:, blocked_ttl_hours:)
    task_ref = snapshot["ref"].to_s.strip
    return nil if task_ref.empty? || active_refs.include?(task_ref)

    status = snapshot["status"].to_s
    labels = Array(snapshot["labels"]).map(&:to_s).to_set
    trigger_present = labels.any? { |label| label.start_with?("trigger:") }
    return nil if NON_CLEANUP_STATUSES.include?(status)
    if status == "Done"
      return "done_ttl>#{done_ttl_hours}h" if artifact_mtime && artifact_mtime <= (now - (done_ttl_hours * 3600))
      return nil
    end
    return "inactive_without_trigger" if ["To do", "Backlog"].include?(status) && !trigger_present

    if labels.include?("blocked") && !trigger_present && artifact_mtime && artifact_mtime <= (now - (blocked_ttl_hours * 3600))
      return "blocked_ttl>#{blocked_ttl_hours}h"
    end
    nil
  end

  def build_cleanup_candidates(root_dir:, project:, task_project_ref:, task_snapshots:, active_refs:, now:, done_ttl_hours:, blocked_ttl_hours:, result_ttl_hours:, log_ttl_hours:, quarantine_ttl_hours:, cache_ttl_hours:, build_output_ttl_hours: 168, max_quarantine_count: nil, max_result_count: nil, max_log_count: nil, max_quarantine_bytes: nil, max_result_bytes: nil, max_log_bytes: nil, max_cache_bytes: nil, max_build_output_bytes: nil)
    candidates = []
    snapshots_by_ref = build_snapshot_index(task_snapshots)
    known_task_refs = task_snapshots.each_with_object(Set.new) do |snapshot, refs|
      value = snapshot["ref"].to_s.strip
      refs << value unless value.empty?
    end
    task_snapshots.each do |snapshot|
      task_ref = snapshot["ref"].to_s.strip
      next if task_ref.empty?

      paths = collect_task_paths(root_dir: root_dir, project: project, task_ref: task_ref)
      next if paths.empty?

      reason = cleanup_reason_for_snapshot(
        snapshot: snapshot,
        active_refs: active_refs,
        artifact_mtime: latest_mtime(paths),
        now: now,
        done_ttl_hours: done_ttl_hours,
        blocked_ttl_hours: blocked_ttl_hours
      )
      next if reason.nil?

      paths.each do |path|
        path_kind = classify_cleanup_path(root_dir: root_dir, path: path)
        artifact_mtime = File.mtime(path).utc
        path_reason =
          case path_kind
          when "result_file"
            next if artifact_mtime > (now - (result_ttl_hours * 3600))
            "result_ttl>#{result_ttl_hours}h (#{reason})"
          when "log_dir"
            next if artifact_mtime > (now - (log_ttl_hours * 3600))
            "log_ttl>#{log_ttl_hours}h (#{reason})"
          else
            reason
          end
        candidates << CleanupCandidate.new(kind: path_kind, path: path.to_s, reason: path_reason, task_ref: task_ref)
      end
    end

    orphan_paths = collect_orphan_paths(
      root_dir: root_dir,
      project: project,
      task_project_ref: task_project_ref,
      known_task_refs: known_task_refs,
      active_refs: active_refs
    )
    orphan_paths.each do |path|
      path_kind = classify_cleanup_path(root_dir: root_dir, path: path)
      artifact_mtime = File.mtime(path).utc
      reason =
        case path_kind
        when "result_file"
          next if artifact_mtime > (now - (result_ttl_hours * 3600))
          "orphan_result_ttl>#{result_ttl_hours}h"
        when "log_dir"
          next if artifact_mtime > (now - (log_ttl_hours * 3600))
          "orphan_log_ttl>#{log_ttl_hours}h"
        else
          next if artifact_mtime > (now - (done_ttl_hours * 3600))
          "orphan_workspace_ttl>#{done_ttl_hours}h"
        end
      candidates << CleanupCandidate.new(kind: path_kind, path: path.to_s, reason: reason, task_ref: nil)
    end
    candidates.concat(
      build_current_scheduler_cleanup_candidates(
        root_dir: root_dir,
        project: project,
        snapshots_by_ref: snapshots_by_ref,
        active_refs: active_refs,
        now: now,
        quarantine_ttl_hours: quarantine_ttl_hours
      )
    )
    candidates.concat(
      build_cache_cleanup_candidates(
        root_dir: root_dir,
        now: now,
        cache_ttl_hours: cache_ttl_hours
      )
    )
    candidates.concat(
      build_quarantine_build_output_candidates(
        root_dir: root_dir,
        project: project,
        snapshots_by_ref: snapshots_by_ref,
        active_refs: active_refs,
        now: now,
        build_output_ttl_hours: build_output_ttl_hours
      )
    )
    candidates.concat(
      build_quarantine_budget_candidates(
        root_dir: root_dir,
        project: project,
        snapshots_by_ref: snapshots_by_ref,
        active_refs: active_refs,
        max_quarantine_count: max_quarantine_count
      )
    )
    candidates.concat(
      build_result_budget_candidates(
        root_dir: root_dir,
        project: project,
        task_project_ref: task_project_ref,
        snapshots_by_ref: snapshots_by_ref,
        active_refs: active_refs,
        max_result_count: max_result_count
      )
    )
    candidates.concat(
      build_log_budget_candidates(
        root_dir: root_dir,
        project: project,
        task_project_ref: task_project_ref,
        snapshots_by_ref: snapshots_by_ref,
        active_refs: active_refs,
        max_log_count: max_log_count
      )
    )
    candidates.concat(
      build_quarantine_size_budget_candidates(
        root_dir: root_dir,
        project: project,
        snapshots_by_ref: snapshots_by_ref,
        active_refs: active_refs,
        max_quarantine_bytes: max_quarantine_bytes
      )
    )
    candidates.concat(
      build_result_size_budget_candidates(
        root_dir: root_dir,
        project: project,
        task_project_ref: task_project_ref,
        snapshots_by_ref: snapshots_by_ref,
        active_refs: active_refs,
        max_result_bytes: max_result_bytes
      )
    )
    candidates.concat(
      build_log_size_budget_candidates(
        root_dir: root_dir,
        project: project,
        task_project_ref: task_project_ref,
        snapshots_by_ref: snapshots_by_ref,
        active_refs: active_refs,
        max_log_bytes: max_log_bytes
      )
    )
    candidates.concat(
      build_cache_size_budget_candidates(
        root_dir: root_dir,
        max_cache_bytes: max_cache_bytes
      )
    )
    candidates.concat(
      build_build_output_size_budget_candidates(
        root_dir: root_dir,
        project: project,
        snapshots_by_ref: snapshots_by_ref,
        active_refs: active_refs,
        max_build_output_bytes: max_build_output_bytes
      )
    )
    candidates
  end

  def build_current_scheduler_cleanup_candidates(root_dir:, project:, snapshots_by_ref:, active_refs:, now:, quarantine_ttl_hours:)
    storage_root = current_scheduler_storage_dir(root_dir: root_dir, project: project)
    quarantine_root = storage_root.join("quarantine")
    return [] unless quarantine_root.exist?

    project_ref = canonical_project_ref(project)
    quarantine_root.children.sort.each_with_object([]) do |path, candidates|
      next unless path.directory?

      task_ref = task_ref_from_slug(project_ref: project_ref, slug: path.basename.to_s)
      next if task_ref && active_refs.include?(task_ref)

      snapshot = task_ref && snapshots_by_ref[task_ref]
      status = snapshot && snapshot["status"].to_s
      next if NON_CLEANUP_STATUSES.include?(status)

      artifact_mtime = File.mtime(path).utc
      next if artifact_mtime > (now - (quarantine_ttl_hours * 3600))

      reason = snapshot ? "quarantine_ttl>#{quarantine_ttl_hours}h" : "orphan_quarantine_ttl>#{quarantine_ttl_hours}h"
      candidates << CleanupCandidate.new(kind: "quarantine_workspace", path: path.to_s, reason: reason, task_ref: task_ref)
    end
  end

  def build_cache_cleanup_candidates(root_dir:, now:, cache_ttl_hours:)
    cache_root = Pathname(root_dir).join(".work", "cache")
    return [] unless cache_root.exist?

    cache_root.children.sort.each_with_object([]) do |path, candidates|
      next unless DISPOSABLE_CACHE_TOP_LEVELS.include?(path.basename.to_s)
      next unless path.exist?

      artifact_mtime = File.mtime(path).utc
      next if artifact_mtime > (now - (cache_ttl_hours * 3600))

      candidates << CleanupCandidate.new(kind: "cache_dir", path: path.to_s, reason: "cache_ttl>#{cache_ttl_hours}h", task_ref: nil)
    end
  end

  def quarantine_build_output_entries(root_dir:, project:, snapshots_by_ref:, active_refs:)
    quarantine_root = current_scheduler_storage_dir(root_dir: root_dir, project: project).join("quarantine")
    return [] unless quarantine_root.exist?

    project_ref = canonical_project_ref(project)
    entries = []
    Find.find(quarantine_root.to_s) do |entry|
      path = Pathname(entry)
      next unless path.directory?

      relative = path.relative_path_from(quarantine_root)
      parts = relative.each_filename.to_a
      next if parts.empty?
      next unless build_output_path_parts?(["quarantine", *parts])

      task_slug = parts.first
      task_ref = task_ref_from_slug(project_ref: project_ref, slug: task_slug)
      next unless cleanup_eligible_task?(task_ref: task_ref, snapshots_by_ref: snapshots_by_ref, active_refs: active_refs)

      entries << [path, task_ref]
      Find.prune
    end
    entries
  end

  def build_quarantine_build_output_candidates(root_dir:, project:, snapshots_by_ref:, active_refs:, now:, build_output_ttl_hours:)
    quarantine_build_output_entries(
      root_dir: root_dir,
      project: project,
      snapshots_by_ref: snapshots_by_ref,
      active_refs: active_refs
    ).each_with_object([]) do |(path, task_ref), candidates|
      artifact_mtime = File.mtime(path).utc
      next if artifact_mtime > (now - (build_output_ttl_hours * 3600))

      candidates << CleanupCandidate.new(
        kind: "build_output_dir",
        path: path.to_s,
        reason: "build_output_ttl>#{build_output_ttl_hours}h",
        task_ref: task_ref
      )
    end
  end

  def build_quarantine_budget_candidates(root_dir:, project:, snapshots_by_ref:, active_refs:, max_quarantine_count:)
    return [] unless max_quarantine_count

    quarantine_root = current_scheduler_storage_dir(root_dir: root_dir, project: project).join("quarantine")
    return [] unless quarantine_root.exist?

    project_ref = canonical_project_ref(project)
    entries = quarantine_root.children.sort.filter do |path|
      next false unless path.directory?

      task_ref = task_ref_from_slug(project_ref: project_ref, slug: path.basename.to_s)
      cleanup_eligible_task?(task_ref: task_ref, snapshots_by_ref: snapshots_by_ref, active_refs: active_refs)
    end
    build_budget_candidates(
      entries: entries,
      max_count: max_quarantine_count,
      kind: "quarantine_workspace",
      reason: "quarantine_count>#{max_quarantine_count}"
    ) do |path|
      task_ref_from_slug(project_ref: project_ref, slug: path.basename.to_s)
    end
  end

  def build_result_budget_candidates(root_dir:, project:, task_project_ref:, snapshots_by_ref:, active_refs:, max_result_count:)
    return [] unless max_result_count

    project_ref = task_project_ref || canonical_project_ref(project)
    results_root = Pathname(root_dir).join(".work", "a3", "results", project.downcase)
    return [] unless results_root.exist?

    entries = results_root.glob("*.json").sort.filter do |path|
      task_ref = task_ref_from_result_path(project_ref: project_ref, path: path)
      cleanup_eligible_task?(task_ref: task_ref, snapshots_by_ref: snapshots_by_ref, active_refs: active_refs)
    end
    build_budget_candidates(
      entries: entries,
      max_count: max_result_count,
      kind: "result_file",
      reason: "result_count>#{max_result_count}"
    ) do |path|
      task_ref_from_result_path(project_ref: project_ref, path: path)
    end
  end

  def build_log_budget_candidates(root_dir:, project:, task_project_ref:, snapshots_by_ref:, active_refs:, max_log_count:)
    return [] unless max_log_count

    project_ref = task_project_ref || canonical_project_ref(project)
    logs_root = Pathname(root_dir).join(".work", "a3", "results", "logs", project.downcase)
    return [] unless logs_root.exist?

    entries = logs_root.children.sort.filter do |path|
      next false unless path.directory?

      task_ref = task_ref_from_log_dir(project_ref: project_ref, path: path)
      cleanup_eligible_task?(task_ref: task_ref, snapshots_by_ref: snapshots_by_ref, active_refs: active_refs)
    end
    build_budget_candidates(
      entries: entries,
      max_count: max_log_count,
      kind: "log_dir",
      reason: "log_count>#{max_log_count}"
    ) do |path|
      task_ref_from_log_dir(project_ref: project_ref, path: path)
    end
  end

  def build_budget_candidates(entries:, max_count:, kind:, reason:)
    return [] if max_count.nil? || max_count < 0

    surplus = entries.sort_by { |path| File.mtime(path).utc }.reverse.drop(max_count)
    surplus.map do |path|
      CleanupCandidate.new(kind: kind, path: path.to_s, reason: reason, task_ref: yield(path))
    end
  end

  def path_size_bytes(path)
    if path.symlink? || path.file?
      File.lstat(path).size
    elsif path.directory?
      total = 0
      Find.find(path.to_s) do |entry|
        candidate = Pathname(entry)
        next if candidate == path

        total += File.lstat(candidate).size unless candidate.directory? && !candidate.symlink?
      end
      total
    else
      0
    end
  end

  def build_size_budget_candidates(entries:, max_bytes:, kind:, reason:)
    return [] if max_bytes.nil? || max_bytes < 0

    ordered = entries.sort_by { |path| File.mtime(path).utc }.reverse
    kept_bytes = 0
    surplus = []
    ordered.each do |path|
      size = path_size_bytes(path)
      if kept_bytes + size <= max_bytes
        kept_bytes += size
      else
        surplus << path
      end
    end
    surplus.map do |path|
      CleanupCandidate.new(kind: kind, path: path.to_s, reason: reason, task_ref: yield(path))
    end
  end

  def build_quarantine_size_budget_candidates(root_dir:, project:, snapshots_by_ref:, active_refs:, max_quarantine_bytes:)
    return [] unless max_quarantine_bytes

    quarantine_root = current_scheduler_storage_dir(root_dir: root_dir, project: project).join("quarantine")
    return [] unless quarantine_root.exist?

    project_ref = canonical_project_ref(project)
    entries = quarantine_root.children.sort.filter do |path|
      next false unless path.directory?

      task_ref = task_ref_from_slug(project_ref: project_ref, slug: path.basename.to_s)
      cleanup_eligible_task?(task_ref: task_ref, snapshots_by_ref: snapshots_by_ref, active_refs: active_refs)
    end
    build_size_budget_candidates(
      entries: entries,
      max_bytes: max_quarantine_bytes,
      kind: "quarantine_workspace",
      reason: "quarantine_bytes>#{max_quarantine_bytes}"
    ) do |path|
      task_ref_from_slug(project_ref: project_ref, slug: path.basename.to_s)
    end
  end

  def build_result_size_budget_candidates(root_dir:, project:, task_project_ref:, snapshots_by_ref:, active_refs:, max_result_bytes:)
    return [] unless max_result_bytes

    project_ref = task_project_ref || canonical_project_ref(project)
    results_root = Pathname(root_dir).join(".work", "a3", "results", project.downcase)
    return [] unless results_root.exist?

    entries = results_root.glob("*.json").sort.filter do |path|
      task_ref = task_ref_from_result_path(project_ref: project_ref, path: path)
      cleanup_eligible_task?(task_ref: task_ref, snapshots_by_ref: snapshots_by_ref, active_refs: active_refs)
    end
    build_size_budget_candidates(
      entries: entries,
      max_bytes: max_result_bytes,
      kind: "result_file",
      reason: "result_bytes>#{max_result_bytes}"
    ) do |path|
      task_ref_from_result_path(project_ref: project_ref, path: path)
    end
  end

  def build_log_size_budget_candidates(root_dir:, project:, task_project_ref:, snapshots_by_ref:, active_refs:, max_log_bytes:)
    return [] unless max_log_bytes

    project_ref = task_project_ref || canonical_project_ref(project)
    logs_root = Pathname(root_dir).join(".work", "a3", "results", "logs", project.downcase)
    return [] unless logs_root.exist?

    entries = logs_root.children.sort.filter do |path|
      next false unless path.directory?

      task_ref = task_ref_from_log_dir(project_ref: project_ref, path: path)
      cleanup_eligible_task?(task_ref: task_ref, snapshots_by_ref: snapshots_by_ref, active_refs: active_refs)
    end
    build_size_budget_candidates(
      entries: entries,
      max_bytes: max_log_bytes,
      kind: "log_dir",
      reason: "log_bytes>#{max_log_bytes}"
    ) do |path|
      task_ref_from_log_dir(project_ref: project_ref, path: path)
    end
  end

  def build_cache_size_budget_candidates(root_dir:, max_cache_bytes:)
    return [] unless max_cache_bytes

    cache_root = Pathname(root_dir).join(".work", "cache")
    return [] unless cache_root.exist?

    entries = cache_root.children.sort.filter do |path|
      DISPOSABLE_CACHE_TOP_LEVELS.include?(path.basename.to_s) && path.exist?
    end
    build_size_budget_candidates(
      entries: entries,
      max_bytes: max_cache_bytes,
      kind: "cache_dir",
      reason: "cache_bytes>#{max_cache_bytes}"
    ) { nil }
  end

  def build_build_output_size_budget_candidates(root_dir:, project:, snapshots_by_ref:, active_refs:, max_build_output_bytes:)
    return [] unless max_build_output_bytes

    entries = quarantine_build_output_entries(
      root_dir: root_dir,
      project: project,
      snapshots_by_ref: snapshots_by_ref,
      active_refs: active_refs
    )
    build_size_budget_candidates(
      entries: entries.map(&:first),
      max_bytes: max_build_output_bytes,
      kind: "build_output_dir",
      reason: "build_output_bytes>#{max_build_output_bytes}"
    ) do |path|
      match = entries.find { |entry, _task_ref| entry == path }
      match && match.last
    end
  end

  def apply_cleanup_candidates(candidates)
    removed = []
    seen = Set.new
    candidates.each do |candidate|
      next if seen.include?(candidate.path)

      seen << candidate.path
      path = Pathname(candidate.path)
      next unless path.exist? || path.symlink?

      if path.directory? && !path.symlink?
        FileUtils.rm_r(path)
      else
        File.delete(path)
      end
      removed << candidate.to_h
    end
    removed
  end

  def build_targeted_runtime_cleanup_candidates(root_dir:, project:, task_refs:, active_refs:)
    candidates = []
    task_refs.uniq.each do |task_ref|
      next if task_ref.to_s.strip.empty? || active_refs.include?(task_ref)

      collect_task_paths(root_dir: root_dir, project: project, task_ref: task_ref).each do |path|
        next unless classify_cleanup_path(root_dir: root_dir, path: path) == "runtime_workspace"

        candidates << CleanupCandidate.new(
          kind: "runtime_workspace",
          path: path.to_s,
          reason: "targeted_post_run_cleanup",
          task_ref: task_ref
        )
      end
    end
    candidates
  end

  def apply_targeted_runtime_cleanup(root_dir:, project:, task_refs:, active_runs_file:, worker_runs_file:)
    active_refs = load_active_refs(active_runs_file: active_runs_file, worker_runs_file: worker_runs_file)
    candidates = build_targeted_runtime_cleanup_candidates(
      root_dir: root_dir,
      project: project,
      task_refs: task_refs,
      active_refs: active_refs
    )
    apply_cleanup_candidates(candidates)
  end

  def parse_args(argv)
    options = {
      done_ttl_hours: 24,
      blocked_ttl_hours: 24,
      result_ttl_hours: 168,
      log_ttl_hours: 168,
      quarantine_ttl_hours: 168,
      cache_ttl_hours: 168,
      build_output_ttl_hours: 168,
      max_quarantine_count: nil,
      max_result_count: nil,
      max_log_count: nil,
      max_quarantine_bytes: nil,
      max_result_bytes: nil,
      max_log_bytes: nil,
      max_cache_bytes: nil,
      max_build_output_bytes: nil,
      apply: false
    }
    parser = OptionParser.new
    parser.banner = "usage: cleanup.rb --project NAME --root-dir DIR --active-runs-file FILE --worker-runs-file FILE [options]"
    parser.on("--project VALUE") { |value| options[:project] = value }
    parser.on("--kanban-project VALUE") { |value| options[:kanban_project] = value }
    parser.on("--root-dir VALUE") { |value| options[:root_dir] = value }
    parser.on("--active-runs-file VALUE") { |value| options[:active_runs_file] = value }
    parser.on("--worker-runs-file VALUE") { |value| options[:worker_runs_file] = value }
    parser.on("--launcher-config VALUE") { |value| options[:launcher_config] = value }
    parser.on("--done-ttl-hours VALUE", Integer) { |value| options[:done_ttl_hours] = value }
    parser.on("--blocked-ttl-hours VALUE", Integer) { |value| options[:blocked_ttl_hours] = value }
    parser.on("--result-ttl-hours VALUE", Integer) { |value| options[:result_ttl_hours] = value }
    parser.on("--log-ttl-hours VALUE", Integer) { |value| options[:log_ttl_hours] = value }
    parser.on("--quarantine-ttl-hours VALUE", Integer) { |value| options[:quarantine_ttl_hours] = value }
    parser.on("--cache-ttl-hours VALUE", Integer) { |value| options[:cache_ttl_hours] = value }
    parser.on("--build-output-ttl-hours VALUE", Integer) { |value| options[:build_output_ttl_hours] = value }
    parser.on("--max-quarantine-count VALUE", Integer) { |value| options[:max_quarantine_count] = value }
    parser.on("--max-result-count VALUE", Integer) { |value| options[:max_result_count] = value }
    parser.on("--max-log-count VALUE", Integer) { |value| options[:max_log_count] = value }
    parser.on("--max-quarantine-bytes VALUE", Integer) { |value| options[:max_quarantine_bytes] = value }
    parser.on("--max-result-bytes VALUE", Integer) { |value| options[:max_result_bytes] = value }
    parser.on("--max-log-bytes VALUE", Integer) { |value| options[:max_log_bytes] = value }
    parser.on("--max-cache-bytes VALUE", Integer) { |value| options[:max_cache_bytes] = value }
    parser.on("--max-build-output-bytes VALUE", Integer) { |value| options[:max_build_output_bytes] = value }
    parser.on("--apply") { options[:apply] = true }
    parser.parse!(argv)

    %i[project root_dir active_runs_file worker_runs_file].each do |key|
      raise OptionParser::MissingArgument, "--#{key.to_s.tr('_', '-')}" if options[key].to_s.empty?
    end
    options
  end

  def main(argv = ARGV, out: $stdout)
    options = parse_args(argv.dup)
    root_dir = Pathname(options.fetch(:root_dir))
    launcher_config = options[:launcher_config] && Pathname(options[:launcher_config])
    snapshots = load_task_snapshots(
      root_dir: root_dir,
      project: options[:kanban_project] || options.fetch(:project),
      launcher_config: launcher_config
    )
    active_refs = load_active_refs(
      active_runs_file: options.fetch(:active_runs_file),
      worker_runs_file: options.fetch(:worker_runs_file)
    )
    now = Time.now.utc
    candidates = build_cleanup_candidates(
      root_dir: root_dir,
      project: options.fetch(:project),
      task_project_ref: options[:kanban_project],
      task_snapshots: snapshots,
      active_refs: active_refs,
      now: now,
      done_ttl_hours: options.fetch(:done_ttl_hours),
      blocked_ttl_hours: options.fetch(:blocked_ttl_hours),
      result_ttl_hours: options.fetch(:result_ttl_hours),
      log_ttl_hours: options.fetch(:log_ttl_hours),
      quarantine_ttl_hours: options.fetch(:quarantine_ttl_hours),
      cache_ttl_hours: options.fetch(:cache_ttl_hours),
      build_output_ttl_hours: options.fetch(:build_output_ttl_hours),
      max_quarantine_count: options[:max_quarantine_count],
      max_result_count: options[:max_result_count],
      max_log_count: options[:max_log_count],
      max_quarantine_bytes: options[:max_quarantine_bytes],
      max_result_bytes: options[:max_result_bytes],
      max_log_bytes: options[:max_log_bytes],
      max_cache_bytes: options[:max_cache_bytes],
      max_build_output_bytes: options[:max_build_output_bytes]
    )
    removed = options[:apply] ? apply_cleanup_candidates(candidates) : []
    out.puts(
      JSON.pretty_generate(
        {
          "status" => "ok",
          "mode" => "cleanup",
          "project" => options.fetch(:project),
          "dry_run" => !options[:apply],
          "candidate_count" => candidates.length,
          "candidates" => candidates.map(&:to_h),
          "removed" => removed,
          "active_refs" => active_refs.to_a.sort
        }
      )
    )
    0
  rescue OptionParser::ParseError => e
    warn(e.message)
    1
  end
end

if $PROGRAM_NAME == __FILE__
  exit(A3Cleanup.main)
end
