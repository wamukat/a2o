# frozen_string_literal: true

require "json"
require "pathname"
require "tempfile"
require "open3"

ROOT_DIR = Pathname(ENV["A2O_ROOT_DIR"] || ENV.fetch("A3_ROOT_DIR", Dir.pwd)).expand_path.freeze
def env_compat(public_name, legacy_name)
  value = ENV[public_name]
  return value unless value.to_s.strip.empty?

  ENV[legacy_name]
end

LAUNCHER_CONFIG_PATH = env_compat("A2O_WORKER_LAUNCHER_CONFIG_PATH", "A3_WORKER_LAUNCHER_CONFIG_PATH")
KNOWN_EXECUTOR_PHASES = %w[implementation review parent_review].freeze
ALLOWED_EXECUTOR_PLACEHOLDERS = {
  "result_path" => :result_path,
  "schema_path" => :schema_path,
  "workspace_root" => :workspace_root,
  "a2o_root_dir" => :a2o_root_dir,
  "root_dir" => :root_dir
}.freeze

def load_json(path)
  JSON.parse(Pathname(path).read)
end

def write_json(path, payload)
  path = Pathname(path)
  path.dirname.mkpath
  path.write(JSON.pretty_generate(payload))
end

def sanitize_diagnostic_value(value)
  case value
  when Hash
    value.transform_values { |item| sanitize_diagnostic_value(item) }
  when Array
    value.map { |item| sanitize_diagnostic_value(item) }
  when String
    value
      .gsub("A3_WORKER_REQUEST_PATH", "A2O_WORKER_REQUEST_PATH")
      .gsub("A3_WORKER_RESULT_PATH", "A2O_WORKER_RESULT_PATH")
      .gsub("A3_WORKSPACE_ROOT", "A2O_WORKSPACE_ROOT")
      .gsub("A3_WORKER_LAUNCHER_CONFIG_PATH", "A2O_WORKER_LAUNCHER_CONFIG_PATH")
      .gsub("A3_ROOT_DIR", "A2O_ROOT_DIR")
      .gsub("/tmp/a3-engine/lib/a3", "<runtime-preset-dir>/lib/a2o-internal")
      .gsub("/tmp/a3-engine", "<runtime-preset-dir>")
      .gsub("/usr/local/bin/a3", "<engine-entrypoint>")
      .gsub("lib/a3", "lib/a2o-internal")
      .gsub(".a3", "<agent-metadata>")
  else
    value
  end
end

def failure(request, summary:, command:, observed_state:, diagnostics: {})
  category = error_category(summary: summary, observed_state: observed_state, phase: request["phase"])
  payload = {
    "task_ref" => request["task_ref"],
    "run_ref" => request["run_ref"],
    "phase" => request["phase"],
    "success" => false,
    "summary" => summary,
    "failing_command" => sanitize_diagnostic_value(command.join(" ")),
    "observed_state" => observed_state,
    "rework_required" => false,
    "diagnostics" => sanitize_diagnostic_value(diagnostics).merge(
      "error_category" => category,
      "remediation" => remediation_for(category)
    )
  }
  if request["phase"] == "review" && request.dig("phase_runtime", "task_kind").to_s == "parent"
    payload["review_disposition"] = {
      "kind" => "blocked",
      "repo_scope" => "unresolved",
      "summary" => summary,
      "description" => "Parent review failed before producing a canonical review disposition. observed_state=#{observed_state}",
      "finding_key" => "parent-review-runtime-failure"
    }
  end
  payload
end

def error_category(summary:, observed_state:, phase:)
  text = [summary, observed_state, phase].join(" ").downcase
  return "configuration_error" if text.match?(/config|schema|project\.yaml|executor config|invalid_executor_config|launcher/)
  return "workspace_dirty" if text.match?(/slot .* has changes|changed files|working tree is dirty/)
  return "verification_failed" if phase.to_s == "verification"
  return "workspace_dirty" if text.match?(/dirty|has changes|untracked|working tree/)
  return "merge_conflict" if text.match?(/merge conflict|conflict marker|unmerged/)
  return "merge_failed" if phase.to_s == "merge"

  "executor_failed"
end

def remediation_for(category)
  {
    "configuration_error" => "Review project.yaml and executor settings. Do not edit generated launcher.json files.",
    "workspace_dirty" => "Clean, commit, or stash the reported repo files before rerunning A2O.",
    "verification_failed" => "Inspect the verification command output and fix product tests, lint, or dependencies.",
    "merge_conflict" => "Resolve the merge conflict or update the base branch before rerunning A2O.",
    "merge_failed" => "Check the merge target ref and branch policy before rerunning A2O.",
    "executor_failed" => "Check that the executor binary, credentials, and worker result JSON are valid."
  }.fetch(category, "Inspect failing_command, observed_state, and evidence, then remove the blocking cause.")
end

def bundle_for(request)
  phase = request["phase"].to_s
  review_scopes = valid_review_disposition_repo_scopes(request, include_unresolved: phase == "review")
  instruction = +"You are the A2O worker. Work only under slot_paths. Follow AGENTS.md and repo Taskfile conventions. "
  instruction << "Do not update kanban directly. Treat request.task_packet as the primary source of truth for what to implement or review before inferring from repository context. Return only the final JSON object required by response_contract."
  if phase == "implementation"
    instruction << " For implementation success, make the required code change, leave git staging/commit publication to the outer A2O runtime, and include changed_files keyed by slot name with relative paths to publish."
    instruction << " After you finish implementation, perform a final self-review before returning. When that self-review is clean, include review_disposition with kind=completed so the outer runtime can preserve review evidence without a separate review phase."
  elsif phase == "review"
    if request.dig("phase_runtime", "task_kind").to_s == "parent"
      instruction << " For parent review, always include review_disposition. Use kind=completed when review is clean, kind=follow_up_child with a configured slot repo_scope for code follow-up, and kind=blocked with repo_scope unresolved when the finding should block the parent. Valid repo_scope values for this request: #{review_scopes.join(', ')}. Parent review must not rely on rework_required routing."
    else
      instruction << " For review, report success only when you found no findings; otherwise return success=false with a short summary and set rework_required=true for code findings that should go back to implementation. Reserve rework_required=false for infrastructure or launch failures that should stay blocked. For review findings, you may set failing_command to null."
    end
  end
  JSON.pretty_generate(
    {
      "type" => "a2o-worker-stdin-bundle",
      "instruction" => instruction,
      "request" => request,
      "response_contract" => {
        "mode" => "json-object",
        "required_keys" => [
          "task_ref",
          "run_ref",
          "phase",
          "success",
          "summary",
          "failing_command",
          "observed_state",
          "rework_required"
        ],
        "notes" => [
          "Return a single JSON object only.",
          "Always include task_ref, run_ref, phase, success, summary, failing_command, observed_state, and rework_required.",
          "Use null for failing_command and observed_state when success is true.",
          "For review failures with rework_required=true, failing_command may be null.",
          "Set rework_required=false unless this is a review failure caused by findings that should return to implementation.",
          "For implementation success, include changed_files as an object like {\"repo_alpha\": [\"src/main.rb\"]} using only relative paths under each slot.",
          "For implementation success, you may include review_disposition when the final self-review is clean.",
          "For review failures caused by findings, include rework_required=true.",
          "For parent review, include review_disposition with kind, repo_scope, summary, description, and finding_key."
        ]
      },
      "operating_contract" => {
        "workspace_root" => env_compat("A2O_WORKSPACE_ROOT", "A3_WORKSPACE_ROOT"),
        "slot_paths" => request["slot_paths"] || {},
        "phase_runtime" => request["phase_runtime"] || {},
        "rules" => [
          "Only inspect and modify files under slot_paths.",
          "Read request.task_packet.title and request.task_packet.description before planning work.",
          "Treat phase_runtime.verification_commands as runner-owned unless explicitly needed for the phase."
        ]
      }
    }
  )
end

def response_schema(request)
  parent_review = request["phase"] == "review" && request.dig("phase_runtime", "task_kind").to_s == "parent"
  implementation_phase = request["phase"] == "implementation"
  properties = {
    "task_ref" => { "type" => "string" },
    "run_ref" => { "type" => "string" },
    "phase" => { "type" => "string" },
    "success" => { "type" => "boolean" },
    "summary" => { "type" => "string" },
    "failing_command" => { "type" => ["string", "null"] },
    "observed_state" => { "type" => ["string", "null"] },
    "rework_required" => { "type" => "boolean" }
  }
  required_fields = [
    "task_ref",
    "run_ref",
    "phase",
    "success",
    "summary",
    "failing_command",
    "observed_state",
    "rework_required"
  ]
  if implementation_phase
    properties["changed_files"] = {
      "type" => ["object", "null"],
      "additionalProperties" => {
        "type" => "array",
        "items" => { "type" => "string" }
      }
    }
    properties["review_disposition"] = {
      "type" => ["object", "null"],
      "properties" => {
        "kind" => { "type" => "string" },
        "repo_scope" => { "type" => "string" },
        "summary" => { "type" => "string" },
        "description" => { "type" => "string" },
        "finding_key" => { "type" => "string" }
      },
      "required" => %w[kind repo_scope summary description finding_key],
      "additionalProperties" => false
    }
    required_fields.concat(%w[changed_files review_disposition])
  end
  if parent_review
    properties["review_disposition"] = {
      "type" => "object",
      "properties" => {
        "kind" => { "type" => "string" },
        "repo_scope" => { "type" => "string" },
        "summary" => { "type" => "string" },
        "description" => { "type" => "string" },
        "finding_key" => { "type" => "string" }
      },
      "required" => %w[kind repo_scope summary description finding_key],
      "additionalProperties" => false
    }
    required_fields << "review_disposition"
  end
  {
    "type" => "object",
    "properties" => properties,
    "required" => required_fields,
    "additionalProperties" => false
  }
end

def load_executor_config
  raise ArgumentError, "A2O_WORKER_LAUNCHER_CONFIG_PATH is required for a2o-agent worker stdin-bundle" if LAUNCHER_CONFIG_PATH.to_s.strip.empty?

  load_json(LAUNCHER_CONFIG_PATH).fetch("executor", {})
end

def normalize_executor_env(env, label:)
  raise ArgumentError, "#{label} must be an object" unless env.is_a?(Hash)

  env.each_with_object({}) do |(key, value), normalized|
    unless key.is_a?(String) && !key.empty?
      raise ArgumentError, "#{label} keys must be non-empty strings"
    end
    unless value.is_a?(String)
      raise ArgumentError, "#{label}.#{key} must be a string"
    end

    normalized[key] = value
  end
end

def normalize_executor_profile(profile, *, label:)
  unless profile.is_a?(Hash)
    raise ArgumentError, "#{label} must be an object"
  end

  command = profile["command"]
  env = profile.fetch("env", {})

  unless command.is_a?(Array) && !command.empty? && command.all? { |entry| entry.is_a?(String) && !entry.empty? }
    raise ArgumentError, "#{label}.command must be a non-empty array of non-empty strings"
  end

  {
    "command" => command,
    "env" => normalize_executor_env(env, label: "#{label}.env")
  }
end

def resolve_executor_phase(request)
  phase = request["phase"].to_s
  return "parent_review" if phase == "review" && request.dig("phase_runtime", "task_kind").to_s == "parent"
  return phase if %w[implementation review].include?(phase)

  raise ArgumentError, "unsupported executor phase #{phase.inspect}"
end

def resolve_executor_profile(request, executor:)
  raise ArgumentError, "executor.kind must be command" unless executor["kind"] == "command"
  raise ArgumentError, "executor.prompt_transport must be stdin-bundle" unless executor["prompt_transport"] == "stdin-bundle"
  result_config = executor.fetch("result", {})
  schema_config = executor.fetch("schema", {})
  raise ArgumentError, "executor.result must be an object" unless result_config.is_a?(Hash)
  raise ArgumentError, "executor.schema must be an object" unless schema_config.is_a?(Hash)
  raise ArgumentError, "executor.result.mode must be file" unless result_config["mode"] == "file"
  raise ArgumentError, "executor.schema.mode must be file or none" unless %w[file none].include?(schema_config["mode"])

  default_profile = normalize_executor_profile(executor.fetch("default_profile"), label: "executor.default_profile")
  phase_profiles = executor.fetch("phase_profiles", {})
  raise ArgumentError, "executor.phase_profiles must be an object" unless phase_profiles.is_a?(Hash)

  unknown_keys = phase_profiles.keys.map(&:to_s) - KNOWN_EXECUTOR_PHASES
  raise ArgumentError, "executor.phase_profiles contains unknown phases: #{unknown_keys.join(', ')}" unless unknown_keys.empty?

  normalized_phase_profiles = phase_profiles.each_with_object({}) do |(key, value), profiles|
    phase_profile = value.is_a?(Hash) ? value : nil
    raise ArgumentError, "executor.phase_profiles.#{key} must be an object" unless phase_profile

    normalized = normalize_executor_profile(phase_profile, label: "executor.phase_profiles.#{key}")
    normalized["env"] = default_profile.fetch("env").merge(normalized.fetch("env"))
    profiles[key.to_s] = normalized
  end

  phase_key = resolve_executor_phase(request)
  phase_profile = normalized_phase_profiles[phase_key]
  return default_profile unless phase_profile

  phase_profile
end

def expand_executor_placeholders(command, result_path:, schema_path:)
  workspace_root = env_compat("A2O_WORKSPACE_ROOT", "A3_WORKSPACE_ROOT") || ROOT_DIR.to_s
  root_dir = ENV["A2O_ROOT_DIR"] || ENV["A3_ROOT_DIR"] || workspace_root
  values = {
    "result_path" => result_path.to_s,
    "schema_path" => schema_path.to_s,
    "workspace_root" => workspace_root,
    "a2o_root_dir" => root_dir,
    "root_dir" => root_dir
  }

  command.map do |arg|
    arg.gsub(/\{\{([^}]+)\}\}/) do
      key = Regexp.last_match(1)
      unless ALLOWED_EXECUTOR_PLACEHOLDERS.key?(key)
        raise ArgumentError, "unknown executor command placeholder #{key.inspect}"
      end

      values.fetch(key)
    end
  end
end

def executor_command(result_path:, schema_path:, request:)
  executor = load_executor_config
  profile = resolve_executor_profile(request, executor: executor)
  expand_executor_placeholders(profile.fetch("command"), result_path: result_path, schema_path: schema_path)
end

def executor_env(request:)
  executor = load_executor_config
  resolve_executor_profile(request, executor: executor).fetch("env")
end

def review_disposition_repo_scope_aliases
  aliases = load_executor_config.fetch("review_disposition_repo_scope_aliases", {})
  raise ArgumentError, "executor.review_disposition_repo_scope_aliases must be an object" unless aliases.is_a?(Hash)

  aliases.each_with_object({}) do |(from, to), normalized|
    unless from.is_a?(String) && !from.empty? && to.is_a?(String) && !to.empty?
      raise ArgumentError, "executor.review_disposition_repo_scope_aliases keys and values must be non-empty strings"
    end

    normalized[from] = to
  end
end

def configured_review_disposition_repo_scopes
  scopes = load_executor_config["review_disposition_repo_scopes"]
  return nil if scopes.nil?
  unless scopes.is_a?(Array) && scopes.all? { |scope| scope.is_a?(String) && !scope.empty? }
    raise ArgumentError, "executor.review_disposition_repo_scopes must be an array of non-empty strings"
  end

  scopes.uniq
end

def inferred_review_disposition_repo_scopes(request)
  request.fetch("slot_paths", {}).keys.map(&:to_s).reject(&:empty?).uniq
end

def valid_review_disposition_repo_scopes(request, include_unresolved:)
  scopes = configured_review_disposition_repo_scopes || inferred_review_disposition_repo_scopes(request)
  scopes = scopes.reject { |scope| scope == "unresolved" } unless include_unresolved
  scopes = scopes + ["unresolved"] if include_unresolved
  scopes.uniq
end

def validate_payload(payload, request:)
  return ["worker result payload must be an object"] unless payload.is_a?(Hash)

  normalize_payload!(payload)
  errors = []
  implementation_phase = request["phase"] == "implementation"
  parent_review = request["phase"] == "review" && request.dig("phase_runtime", "task_kind").to_s == "parent"
  errors << "success must be true or false" unless [true, false].include?(payload["success"])
  errors << "summary must be a string" unless payload["summary"].is_a?(String)
  errors << "task_ref must match the worker request" if payload.key?("task_ref") && payload["task_ref"] != request["task_ref"]
  errors << "run_ref must match the worker request" if payload.key?("run_ref") && payload["run_ref"] != request["run_ref"]
  errors << "phase must match the worker request" if payload.key?("phase") && payload["phase"] != request["phase"]

  if payload["success"] == false
    if payload["rework_required"] != true && !payload["failing_command"].is_a?(String)
      errors << "failing_command must be a string when success is false unless rework_required is true"
    end
    errors << "observed_state must be a string when success is false" unless payload["observed_state"].is_a?(String)
  else
    errors << "failing_command must be a string or null when success is true" if payload.key?("failing_command") && !payload["failing_command"].nil? && !payload["failing_command"].is_a?(String)
    errors << "observed_state must be a string or null when success is true" if payload.key?("observed_state") && !payload["observed_state"].nil? && !payload["observed_state"].is_a?(String)
  end

  errors << "diagnostics must be an object" if payload.key?("diagnostics") && !payload["diagnostics"].is_a?(Hash)
  if payload.key?("changed_files")
    changed_files = payload["changed_files"]
    unless changed_files.nil? || changed_files.is_a?(Hash)
      errors << "changed_files must be an object when present"
      return errors
    end
    return errors if changed_files.nil?

    changed_files.each do |slot_name, files|
      errors << "changed_files slot names must be strings" unless slot_name.is_a?(String)
      unless files.is_a?(Array) && files.all? { |entry| entry.is_a?(String) }
        errors << "changed_files for #{slot_name} must be an array of strings"
      end
    end
  elsif implementation_phase && payload["success"] == true
    errors << "changed_files must be present for implementation success"
  end
  if !payload.key?("rework_required") || ![true, false].include?(payload["rework_required"])
    errors << "rework_required must be true or false"
  end
  if payload.key?("review_disposition")
    disposition = payload["review_disposition"]
    return errors if implementation_phase && disposition.nil?

    unless disposition.is_a?(Hash)
      errors << "review_disposition must be an object"
      return errors
    end
    %w[kind repo_scope summary description finding_key].each do |key|
      errors << "review_disposition.#{key} must be a string" unless disposition[key].is_a?(String)
    end
    if parent_review
      valid_kinds = %w[completed follow_up_child blocked]
      valid_repo_scopes = valid_review_disposition_repo_scopes(request, include_unresolved: true)
      errors << "review_disposition.kind must be one of #{valid_kinds.join(', ')}" unless valid_kinds.include?(disposition["kind"])
      errors << "review_disposition.repo_scope must be one of #{valid_repo_scopes.join(', ')}" unless valid_repo_scopes.include?(disposition["repo_scope"])
    elsif implementation_phase
      valid_repo_scopes = valid_review_disposition_repo_scopes(request, include_unresolved: false)
      errors << "review_disposition.kind must be completed for implementation evidence" unless disposition["kind"] == "completed"
      errors << "review_disposition.repo_scope must be one of #{valid_repo_scopes.join(', ')}" unless valid_repo_scopes.include?(disposition["repo_scope"])
    end
  elsif parent_review
    errors << "review_disposition must be present for parent review"
  elsif implementation_phase
    errors << "review_disposition must be present for implementation"
  end
  errors
end

def normalize_payload!(payload)
  disposition = payload["review_disposition"]
  return unless disposition.is_a?(Hash)

  aliases = review_disposition_repo_scope_aliases
  disposition["repo_scope"] = aliases.fetch(disposition["repo_scope"], disposition["repo_scope"])
end

def load_payload(result_path)
  return nil unless result_path.exist?

  raw = result_path.read
  return nil if raw.strip.empty?

  JSON.parse(raw)
end

def main
  request_path = Pathname(env_compat("A2O_WORKER_REQUEST_PATH", "A3_WORKER_REQUEST_PATH") || raise(KeyError, "A2O_WORKER_REQUEST_PATH is required"))
  result_path = Pathname(env_compat("A2O_WORKER_RESULT_PATH", "A3_WORKER_RESULT_PATH") || raise(KeyError, "A2O_WORKER_RESULT_PATH is required"))
  request = load_json(request_path)
  result_path.dirname.mkpath
  result_path.delete if result_path.exist?

  Tempfile.create(["a2o-worker-schema", ".json"]) do |schema_file|
    schema_file.write(JSON.pretty_generate(response_schema(request)))
    schema_file.flush
    begin
      command = executor_command(result_path: result_path, schema_path: Pathname(schema_file.path), request: request)
      command_env = executor_env(request: request)
      stdin_bundle = bundle_for(request)
    rescue ArgumentError => e
      write_json(
        result_path,
        failure(
          request,
          summary: "stdin worker executor config invalid",
          command: ["executor", "command"],
          observed_state: "invalid_executor_config",
          diagnostics: { "error" => e.message }
        )
      )
      return 0
    end
    stdout, stderr, status = Open3.capture3(
      { "PWD" => (env_compat("A2O_WORKSPACE_ROOT", "A3_WORKSPACE_ROOT") || ROOT_DIR.to_s) }.merge(command_env),
      *command,
      stdin_data: stdin_bundle,
      chdir: env_compat("A2O_WORKSPACE_ROOT", "A3_WORKSPACE_ROOT") || ROOT_DIR.to_s
    )

    unless status.success? || result_path.exist?
      write_json(
        result_path,
        failure(
          request,
          summary: "stdin worker launcher failed",
          command: command,
          observed_state: "exit #{status.exitstatus}",
          diagnostics: { "stdout" => stdout, "stderr" => stderr }
        )
      )
      return 0
    end

    begin
      payload = load_payload(result_path)
    rescue JSON::ParserError => e
      write_json(
        result_path,
        failure(
          request,
          summary: "stdin worker returned invalid json",
          command: command,
          observed_state: "invalid_worker_json",
          diagnostics: { "stdout" => stdout, "stderr" => stderr, "error" => e.message }
        )
      )
      return 0
    end

    if payload.nil?
      write_json(
        result_path,
        failure(
          request,
          summary: "stdin worker returned no final result",
          command: command,
          observed_state: "missing_worker_result",
          diagnostics: { "stdout" => stdout, "stderr" => stderr }
        )
      )
      return 0
    end

    begin
      validation_errors = validate_payload(payload, request: request)
    rescue ArgumentError => e
      write_json(
        result_path,
        failure(
          request,
          summary: "stdin worker executor config invalid",
          command: command,
          observed_state: "invalid_executor_config",
          diagnostics: { "error" => e.message }
        )
      )
      return 0
    end
    unless validation_errors.empty?
      write_json(
        result_path,
        failure(
          request,
          summary: "worker result schema invalid",
          command: command,
          observed_state: "invalid_worker_result",
          diagnostics: {
            "validation_errors" => validation_errors,
            "worker_response_bundle" => payload,
            "stdout" => stdout,
            "stderr" => stderr
          }
        )
      )
      return 0
    end

    write_json(result_path, payload)
  end

  0
end

exit(main) if $PROGRAM_NAME == __FILE__
