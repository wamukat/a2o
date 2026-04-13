# frozen_string_literal: true

require "json"
require "pathname"
require "set"

module A3DirectCanaryWorker
  module_function

  def diff_enabled_task_refs(env: ENV)
    env.fetch("A3_DIRECT_CANARY_DIFF_TASK_REFS", "").split(",").map(&:strip).reject(&:empty?).to_set
  end

  def repo_slot_paths(request)
    slot_paths = request.fetch("slot_paths", {})
    unless slot_paths.is_a?(Hash)
      raise "slot_paths must be an object: #{request.fetch('task_ref')}"
    end

    edit_scope = Array(request.fetch("scope_snapshot", {}).fetch("edit_scope", []))
    repo_slots = {}
    slot_paths.each do |slot_name, raw_path|
      next unless slot_name.is_a?(String)
      next unless slot_name.start_with?("repo_")
      next if !edit_scope.empty? && !edit_scope.include?(slot_name)

      repo_slots[slot_name] = Pathname(raw_path.to_s)
    end

    raise "at least one repo_* slot is required for diff canary: #{request.fetch('task_ref')}" if repo_slots.empty?

    repo_slots
  end

  def relative_changed_path(repo_root, path)
    path.relative_path_from(repo_root).to_s
  end

  def safe_task_ref(task_ref)
    task_ref.gsub(/[^A-Za-z0-9._-]+/, "-").gsub(/\A-+|-+\z/, "")
  end

  def maybe_apply_local_live_diff(request, env: ENV)
    task_ref = request.fetch("task_ref").to_s
    unless diff_enabled_task_refs(env: env).include?(task_ref)
      return {
        "worker_mode" => "direct_canary_noop",
        "changed_files" => {}
      }
    end

    unless request.fetch("phase") == "implementation"
      return {
        "worker_mode" => "direct_canary_diff_passthrough",
        "diff_applied" => false,
        "reason" => "non_implementation_phase"
      }
    end

    written_markers = []
    changed_files = {}
    repo_slot_paths(request).each do |slot_name, repo_root|
      marker_dir = repo_root.join(".a3-canary", "tasks", safe_task_ref(task_ref))
      marker_dir.mkpath
      marker_path = marker_dir.join("#{slot_name}.md")
      lines = marker_path.exist? ? marker_path.read.split(/\r?\n/).reject(&:empty?) : []

      marker_line = "- #{task_ref} (#{slot_name}): implementation diff generated"
      unless lines.include?(marker_line)
        lines << marker_line
        marker_path.write(lines.join("\n") + "\n")
      end

      written_markers << {
        "slot" => slot_name,
        "marker_path" => marker_path.to_s,
        "marker_line" => marker_line
      }
      changed_files[slot_name] ||= []
      changed_files[slot_name] << relative_changed_path(repo_root, marker_path)
    end

    {
      "worker_mode" => "direct_canary_diff_write",
      "diff_applied" => true,
      "written_markers" => written_markers,
      "changed_files" => changed_files
    }
  end

  def main(env: ENV)
    request_path = Pathname(env.fetch("A3_WORKER_REQUEST_PATH"))
    result_path = Pathname(env.fetch("A3_WORKER_RESULT_PATH"))

    request = JSON.parse(request_path.read)
    diagnostics = maybe_apply_local_live_diff(request, env: env)
    result_path.parent.mkpath
    payload = {
      "task_ref" => request.fetch("task_ref"),
      "run_ref" => request.fetch("run_ref"),
      "phase" => request.fetch("phase"),
      "success" => true,
      "summary" => "A3 direct canary worker completed #{request.fetch('task_ref')} at #{request.fetch('phase')}",
      "failing_command" => nil,
      "observed_state" => nil,
      "rework_required" => false,
      "diagnostics" => { "skill" => request.fetch("skill") }.merge(diagnostics)
    }
    payload["changed_files"] = diagnostics.fetch("changed_files") if request.fetch("phase") == "implementation"
    result_path.write(JSON.pretty_generate(payload))
    0
  end
end

if $PROGRAM_NAME == __FILE__
  exit(A3DirectCanaryWorker.main)
end
