# frozen_string_literal: true

require "json"
require "pathname"
require "tempfile"
require "open3"
require "thread"
require_relative "../domain/repo_scope_compatibility"
require_relative "../domain/refactoring_assessment"
require_relative "../domain/skill_feedback"

def removed_legacy_env_error(public_name, legacy_name)
  KeyError.new(
    "removed A3 compatibility input: environment variable #{legacy_name}; " \
    "migration_required=true replacement=environment variable #{public_name}"
  )
end

def public_env(public_name, legacy_name)
  value = ENV[public_name]
  return value unless value.to_s.strip.empty?

  legacy_value = ENV[legacy_name]
  raise removed_legacy_env_error(public_name, legacy_name) unless legacy_value.to_s.strip.empty?

  nil
end

ROOT_DIR = Pathname(public_env("A2O_ROOT_DIR", "A3_ROOT_DIR") || Dir.pwd).expand_path.freeze
LAUNCHER_CONFIG_PATH = public_env("A2O_WORKER_LAUNCHER_CONFIG_PATH", "A3_WORKER_LAUNCHER_CONFIG_PATH")
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
      .gsub(".a2o", "<agent-metadata>")
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
      "slot_scopes" => ["unresolved"],
      "summary" => summary,
      "description" => "Parent review failed before producing a canonical review disposition. observed_state=#{observed_state}",
      "finding_key" => "parent-review-runtime-failure"
    }
  end
  payload
end

def error_category(summary:, observed_state:, phase:)
  A3::Domain::ErrorCategoryPolicy.worker_error_category(summary: summary, observed_state: observed_state, phase: phase)
end

def remediation_for(category)
  A3::Domain::ErrorCategoryPolicy.worker_remediation(category)
end

def bundle_for(request)
  phase = request["phase"].to_s
  parent_review = phase == "review" && request.dig("phase_runtime", "task_kind").to_s == "parent"
  review_scopes = valid_review_disposition_slot_scopes(request, include_unresolved: phase == "review")
  instruction = +"You are the A2O worker. Work only under slot_paths. Follow AGENTS.md and repo Taskfile conventions. "
  instruction << "Do not update kanban directly. Treat request.task_packet as the primary source of truth for what to implement or review before inferring from repository context. Return only the final JSON object required by response_contract."
  if phase == "implementation"
    instruction << " For implementation success, make the required code change, leave git staging/commit publication to the outer A2O runtime, and include changed_files keyed by slot name with relative paths to publish."
    instruction << " After you finish implementation, perform a final self-review before returning. When that self-review is clean, include review_disposition with kind=completed so the outer runtime can preserve review evidence without a separate review phase."
    instruction << " If request.phase_runtime.prior_review_feedback is present, treat it as mandatory rework input from the previous review and directly address each finding before returning."
  elsif phase == "review"
    if request.dig("phase_runtime", "task_kind").to_s == "parent"
      instruction << " For parent review, include review_disposition unless you return clarification_request. Use kind=completed when review is clean, kind=follow_up_child with slot_scopes for code follow-up, and kind=blocked with slot_scopes=[unresolved] when the finding should block the parent. Use clarification_request instead when the finding needs requester input rather than code follow-up or technical blocking. Valid slot_scopes values for this request: #{review_scopes.join(', ')}. Parent review must not rely on rework_required routing."
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
          "rework_required"
        ],
        "notes" => [
          "Return a single JSON object only.",
          "Always include task_ref, run_ref, phase, success, summary, and rework_required.",
          "Use null for failing_command and observed_state when success is true.",
          "For failures, include failing_command and observed_state unless you return clarification_request.",
          "For review failures with rework_required=true, failing_command may be null.",
          "Set rework_required=false unless this is a review failure caused by findings that should return to implementation.",
          "When requirements are ambiguous or conflicting and you cannot safely continue, return success=false, rework_required=false, and clarification_request with question, optional context/options/recommended_option/impact. This is for requester input, not runtime or validation failures.",
          "For implementation success, include changed_files as an object like {\"repo_alpha\": [\"src/main.rb\"]} using only relative paths under each slot.",
          "For implementation success, you may include review_disposition when the final self-review is clean.",
          "Optionally include refactoring_assessment when implementation or review finds design debt. Use disposition one of none, include_child, defer_follow_up, blocked_by_design_debt, needs_clarification and recommended_action one of none, document_only, include_in_current_child, create_refactoring_child, create_follow_up_child, request_clarification, block_until_decision.",
          "For review failures caused by findings, include rework_required=true.",
          "Copy task_ref, run_ref, and phase exactly from request. If you are uncertain, omit them rather than inventing values.",
          "For parent review, include review_disposition with kind, slot_scopes, summary, and description unless you return clarification_request. Include finding_key only for actionable follow_up_child or blocked findings; completed clean reviews may omit it or set it to null.",
          "For parent review success with no findings, set success=true, observed_state=null, rework_required=false, and review_disposition.kind=completed.",
          "For parent review code follow-up findings, set success=false, observed_state to a concise string such as review_findings, rework_required=false, and review_disposition.kind=follow_up_child with configured slot_scopes.",
          "For parent review blocked findings, set success=false, observed_state to a concise string such as blocked_finding, rework_required=false, and review_disposition.kind=blocked with slot_scopes=[unresolved].",
          "Optionally include skill_feedback when this run revealed reusable project or A2O skill guidance. Use category, summary, proposal.target, and optional repo_scope, skill_path, confidence, evidence, and proposal.suggested_patch. Do not edit skill files directly from this field."
        ],
        "examples" => parent_review ? parent_review_response_examples(request) : []
      },
      "operating_contract" => {
        "workspace_root" => public_env("A2O_WORKSPACE_ROOT", "A3_WORKSPACE_ROOT"),
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

def parent_review_response_examples(request)
  task_ref = request["task_ref"]
  run_ref = request["run_ref"]
  phase = request["phase"] || "review"
  scopes = valid_review_disposition_slot_scopes(request, include_unresolved: true).reject { |scope| scope == "unresolved" }
  slot_scopes = [scopes.first || "repo_alpha"]
  [
    {
      "name" => "parent_review_clean",
      "response" => {
        "task_ref" => task_ref,
        "run_ref" => run_ref,
        "phase" => phase,
        "success" => true,
        "summary" => "Parent review found no findings.",
        "failing_command" => nil,
        "observed_state" => nil,
        "rework_required" => false,
        "review_disposition" => {
          "kind" => "completed",
          "slot_scopes" => slot_scopes,
          "summary" => "No findings",
          "description" => "The parent integration branch is ready to complete.",
          "finding_key" => "no-findings"
        }
      }
    },
    {
      "name" => "parent_review_follow_up_child",
      "response" => {
        "task_ref" => task_ref,
        "run_ref" => run_ref,
        "phase" => phase,
        "success" => false,
        "summary" => "A follow-up child task is required.",
        "failing_command" => nil,
        "observed_state" => "review_findings",
        "rework_required" => false,
        "review_disposition" => {
          "kind" => "follow_up_child",
          "slot_scopes" => slot_scopes,
          "summary" => "Follow-up child required",
          "description" => "The finding is scoped to one configured slot and should be implemented as a child task.",
          "finding_key" => "parent-review-follow-up"
        }
      }
    },
    {
      "name" => "parent_review_blocked",
      "response" => {
        "task_ref" => task_ref,
        "run_ref" => run_ref,
        "phase" => phase,
        "success" => false,
        "summary" => "Parent review is blocked.",
        "failing_command" => "parent_review",
        "observed_state" => "blocked_finding",
        "rework_required" => false,
        "review_disposition" => {
          "kind" => "blocked",
          "slot_scopes" => ["unresolved"],
          "summary" => "Parent review blocked",
          "description" => "The finding cannot be routed to a configured child scope without requester input or technical resolution.",
          "finding_key" => "parent-review-blocked"
        }
      }
    }
  ]
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
    "rework_required" => { "type" => "boolean" },
    "clarification_request" => clarification_request_schema,
    "refactoring_assessment" => refactoring_assessment_schema,
    "skill_feedback" => skill_feedback_schema
  }
  required_fields = [
    "task_ref",
    "run_ref",
    "phase",
    "success",
    "summary",
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
        "slot_scopes" => { "type" => "array", "items" => { "type" => "string" }, "minItems" => 1 },
        "summary" => { "type" => "string" },
        "description" => { "type" => "string" },
        "finding_key" => { "type" => ["string", "null"] }
      },
      "required" => %w[kind slot_scopes summary description],
      "additionalProperties" => false
    }
  end
  if parent_review
    properties["review_disposition"] = {
      "type" => "object",
      "properties" => {
        "kind" => { "type" => "string" },
        "slot_scopes" => { "type" => "array", "items" => { "type" => "string" }, "minItems" => 1 },
        "summary" => { "type" => "string" },
        "description" => { "type" => "string" },
        "finding_key" => { "type" => ["string", "null"] }
      },
      "required" => %w[kind slot_scopes summary description],
      "additionalProperties" => false
    }
  end
  {
    "type" => "object",
    "properties" => properties,
    "required" => required_fields,
    "additionalProperties" => false
  }
end

def clarification_request_schema
  {
    "type" => ["object", "null"],
    "properties" => {
      "question" => { "type" => "string" },
      "context" => { "type" => "string" },
      "options" => {
        "type" => "array",
        "items" => { "type" => "string" }
      },
      "recommended_option" => { "type" => "string" },
      "impact" => { "type" => "string" }
    },
    "required" => ["question"],
    "additionalProperties" => false
  }
end

def refactoring_assessment_schema
  {
    "type" => ["object", "null"],
    "properties" => {
      "disposition" => {
        "type" => "string",
        "enum" => A3::Domain::RefactoringAssessment::DISPOSITIONS
      },
      "reason" => { "type" => "string" },
      "scope" => {
        "type" => "array",
        "items" => { "type" => "string" }
      },
      "recommended_action" => {
        "type" => "string",
        "enum" => A3::Domain::RefactoringAssessment::RECOMMENDED_ACTIONS
      },
      "risk" => {
        "type" => "string",
        "enum" => A3::Domain::RefactoringAssessment::RISKS
      },
      "evidence" => {
        "type" => "array",
        "items" => { "type" => "string" }
      }
    },
    "required" => ["disposition"],
    "additionalProperties" => false
  }
end

def skill_feedback_schema
  feedback_entry = {
    "type" => "object",
    "properties" => {
      "schema" => { "type" => "string" },
      "phase" => { "type" => "string" },
      "repo_scope" => { "type" => "string" },
      "skill_path" => { "type" => "string" },
      "category" => { "type" => "string" },
      "summary" => { "type" => "string" },
      "evidence" => { "type" => "object" },
      "state" => { "type" => "string", "enum" => A3::Domain::SkillFeedback.states },
      "proposal" => {
        "type" => "object",
        "properties" => {
          "target" => { "type" => "string", "enum" => valid_skill_feedback_targets },
          "suggested_patch" => { "type" => "string" }
        },
        "required" => ["target"],
        "additionalProperties" => true
      },
      "confidence" => { "type" => "string" }
    },
    "required" => %w[category summary proposal],
    "additionalProperties" => true
  }
  {
    "anyOf" => [
      feedback_entry,
      {
        "type" => "array",
        "items" => feedback_entry
      },
      { "type" => "null" }
    ]
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
  workspace_root = public_env("A2O_WORKSPACE_ROOT", "A3_WORKSPACE_ROOT") || ROOT_DIR.to_s
  root_dir = public_env("A2O_ROOT_DIR", "A3_ROOT_DIR") || workspace_root
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

def configured_review_disposition_slot_scopes
  return nil if LAUNCHER_CONFIG_PATH.to_s.strip.empty?

  scopes = load_executor_config["review_disposition_slot_scopes"]
  return nil if scopes.nil?
  unless scopes.is_a?(Array) && scopes.all? { |scope| scope.is_a?(String) && !scope.empty? }
    raise ArgumentError, "executor.review_disposition_slot_scopes must be an array of non-empty strings"
  end

  scopes.uniq
end

def inferred_review_disposition_slot_scopes(request)
  request.fetch("slot_paths", {}).keys.map(&:to_s).reject(&:empty?).uniq
end

def valid_review_disposition_slot_scopes(request, include_unresolved:)
  scopes = configured_review_disposition_slot_scopes || inferred_review_disposition_slot_scopes(request)
  scopes = scopes.reject { |scope| scope == "unresolved" } unless include_unresolved
  scopes = scopes + ["unresolved"] if include_unresolved
  scopes.uniq
end

def validate_payload(payload, request:)
  return ["worker result payload must be an object"] unless payload.is_a?(Hash)

  normalize_payload!(payload, request: request)
  canonicalize_identity!(payload, request: request)
  errors = []
  implementation_phase = request["phase"] == "implementation"
  parent_review = request["phase"] == "review" && request.dig("phase_runtime", "task_kind").to_s == "parent"
  errors << "success must be true or false" unless [true, false].include?(payload["success"])
  errors << "summary must be a string" unless payload["summary"].is_a?(String)
  errors << "task_ref must match the worker request" if payload.key?("task_ref") && payload["task_ref"] != request["task_ref"]
  errors << "run_ref must match the worker request" if payload.key?("run_ref") && payload["run_ref"] != request["run_ref"]
  errors << "phase must match the worker request" if payload.key?("phase") && payload["phase"] != request["phase"]

  if payload["success"] == false
    if payload["rework_required"] != true && !clarification_request_present?(payload) && !payload["failing_command"].is_a?(String)
      errors << "failing_command must be a string when success is false unless rework_required is true"
    end
    errors << "observed_state must be a string when success is false" unless clarification_request_present?(payload) || payload["observed_state"].is_a?(String)
  else
    errors << "failing_command must be a string or null when success is true" if payload.key?("failing_command") && !payload["failing_command"].nil? && !payload["failing_command"].is_a?(String)
    errors << "observed_state must be a string or null when success is true" if payload.key?("observed_state") && !payload["observed_state"].nil? && !payload["observed_state"].is_a?(String)
  end

  errors << "diagnostics must be an object" if payload.key?("diagnostics") && !payload["diagnostics"].is_a?(Hash)
  validate_skill_feedback(payload["skill_feedback"]).each { |error| errors << error } if payload.key?("skill_feedback")
  validate_clarification_request(payload["clarification_request"], success: payload["success"]).each { |error| errors << error } if payload.key?("clarification_request")
  if payload.key?("refactoring_assessment")
    A3::Domain::RefactoringAssessment.validation_errors(payload["refactoring_assessment"]).each { |error| errors << error }
  end
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
    if implementation_phase && disposition.nil?
      errors << "review_disposition must be present for implementation success" if payload["success"] == true
      return errors
    end

    unless disposition.is_a?(Hash)
      errors << "review_disposition must be an object"
      return errors
    end
    %w[kind summary description].each do |key|
      errors << "review_disposition.#{key} must be a string" unless disposition[key].is_a?(String)
    end
    if disposition.key?("finding_key") && !disposition["finding_key"].nil? && !disposition["finding_key"].is_a?(String)
      errors << "review_disposition.finding_key must be a string or null"
    end
    if %w[follow_up_child blocked].include?(disposition["kind"]) && !present_string?(disposition["finding_key"])
      errors << "review_disposition.finding_key must be a non-empty string for follow_up_child or blocked"
    end
    if disposition.key?(A3::Domain::RepoScopeCompatibility::LEGACY_REPO_SCOPE_FIELD)
      errors << A3::Domain::RepoScopeCompatibility::REMOVED_REVIEW_DISPOSITION_REPO_SCOPE_ERROR
    end
    slot_scope_errors = validate_review_disposition_slot_scopes(disposition["slot_scopes"])
    errors.concat(slot_scope_errors)
    if parent_review
      valid_kinds = %w[completed follow_up_child blocked]
      valid_slot_scopes = valid_review_disposition_slot_scopes(request, include_unresolved: true)
      errors << "review_disposition.kind must be one of #{valid_kinds.join(', ')}" unless valid_kinds.include?(disposition["kind"])
      invalid_slot_scopes = Array(disposition["slot_scopes"]) - valid_slot_scopes
      errors << "review_disposition.slot_scopes must be one of #{valid_slot_scopes.join(', ')}" unless invalid_slot_scopes.empty?
      errors << "review_disposition.kind must be completed when success is true for parent review" if payload["success"] == true && disposition["kind"] != "completed"
    elsif implementation_phase
      valid_slot_scopes = valid_review_disposition_slot_scopes(request, include_unresolved: false)
      errors << "review_disposition.kind must be completed for implementation evidence" unless disposition["kind"] == "completed"
      invalid_slot_scopes = Array(disposition["slot_scopes"]) - valid_slot_scopes
      errors << "review_disposition.slot_scopes must be one of #{valid_slot_scopes.join(', ')}" unless invalid_slot_scopes.empty?
    end
  elsif parent_review && !clarification_request_present?(payload)
    errors << "review_disposition must be present for parent review"
  elsif implementation_phase && payload["success"] == true
    errors << "review_disposition must be present for implementation success"
  end
  errors
end

def canonicalize_identity!(payload, request:)
  %w[task_ref run_ref phase].each do |key|
    next unless payload.key?(key)
    next if payload[key] == request[key]

    diagnostics = payload["diagnostics"].is_a?(Hash) ? payload["diagnostics"] : {}
    corrections = diagnostics["canonicalized_identity"].is_a?(Hash) ? diagnostics["canonicalized_identity"] : {}
    corrections[key] = {
      "provided" => payload[key],
      "canonical" => request[key]
    }
    diagnostics["canonicalized_identity"] = corrections
    payload["diagnostics"] = diagnostics
    payload[key] = request[key]
  end
end

def validate_clarification_request(value, success:)
  return [] if value.nil?
  return ["clarification_request must be an object when present"] unless value.is_a?(Hash)

  errors = []
  errors << "clarification_request must only be present when success is false" if success == true
  errors << "clarification_request.question must be a non-empty string" unless value["question"].is_a?(String) && !value["question"].strip.empty?
  %w[context recommended_option impact].each do |field|
    errors << "clarification_request.#{field} must be a string when present" if value.key?(field) && !value[field].nil? && !value[field].is_a?(String)
  end
  if value.key?("options")
    options = value["options"]
    unless options.is_a?(Array) && options.all? { |entry| entry.is_a?(String) && !entry.strip.empty? }
      errors << "clarification_request.options must be an array of non-empty strings"
    end
  end
  errors
end

def clarification_request_present?(payload)
  payload["clarification_request"].is_a?(Hash)
end

def normalize_payload!(payload, request:)
  disposition = payload["review_disposition"]
  normalize_skill_feedback!(payload, aliases: {})
  normalize_parent_review_success!(payload, request: request) if payload["success"] == true
end

def normalize_parent_review_success!(payload, request:)
  return unless request.dig("phase_runtime", "task_kind").to_s == "parent"
  return unless request["phase"] == "review"
  return unless payload["rework_required"] == false

  disposition = payload["review_disposition"]
  return if disposition.is_a?(Hash) && present_string?(disposition["kind"]) && disposition["kind"] != "completed"

  normalized_disposition = disposition.is_a?(Hash) ? disposition.dup : {}
  normalized_disposition["kind"] = "completed"
  normalized_disposition["slot_scopes"] = [default_parent_review_slot_scope(request)] if Array(normalized_disposition["slot_scopes"]).empty?
  normalized_disposition["summary"] = payload["summary"] unless present_string?(normalized_disposition["summary"])
  normalized_disposition["description"] = payload["summary"] unless present_string?(normalized_disposition["description"])
  payload["review_disposition"] = normalized_disposition
end

def default_parent_review_slot_scope(request)
  (inferred_review_disposition_slot_scopes(request) + ["unresolved"]).uniq
    .reject { |scope| scope == "unresolved" }
    .fetch(0, "unresolved")
end

def validate_review_disposition_slot_scopes(value)
  unless value.is_a?(Array) && !value.empty? && value.all? { |scope| scope.is_a?(String) && !scope.strip.empty? }
    return ["review_disposition.slot_scopes must be a non-empty array of strings"]
  end

  []
end

def present_string?(value)
  value.is_a?(String) && !value.strip.empty?
end

def normalize_skill_feedback!(payload, aliases:)
  skill_feedback_entries(payload["skill_feedback"]).each do |entry|
    next unless entry.is_a?(Hash) && entry["repo_scope"].is_a?(String)

    entry["repo_scope"] = aliases.fetch(entry["repo_scope"], entry["repo_scope"])
  end
end

def skill_feedback_entries(value)
  case value
  when Hash
    [value]
  when Array
    value
  else
    []
  end
end

def validate_skill_feedback(value)
  return [] if value.nil?

  entries =
    case value
    when Hash
      [value]
    when Array
      value
    else
      return ["skill_feedback must be an object, array of objects, or null when present"]
    end

  entries.each_with_index.flat_map do |entry, index|
    validate_skill_feedback_entry(entry, index)
  end
end

def validate_skill_feedback_entry(entry, index)
  prefix = "skill_feedback[#{index}]"
  return ["#{prefix} must be an object"] unless entry.is_a?(Hash)

  errors = []
  errors << "#{prefix}.category must be a string" unless entry["category"].is_a?(String)
  errors << "#{prefix}.summary must be a string" unless entry["summary"].is_a?(String)
  errors << "#{prefix}.proposal must be an object" unless entry["proposal"].is_a?(Hash)
  if entry["proposal"].is_a?(Hash) && !entry.dig("proposal", "target").is_a?(String)
    errors << "#{prefix}.proposal.target must be a string"
  elsif entry["proposal"].is_a?(Hash) && !valid_skill_feedback_targets.include?(entry.dig("proposal", "target"))
    errors << "#{prefix}.proposal.target must be one of #{valid_skill_feedback_targets.join(', ')}"
  end
  if entry.key?("state") && !A3::Domain::SkillFeedback.states.include?(entry["state"])
    errors << "#{prefix}.state must be one of #{A3::Domain::SkillFeedback.states.join(', ')}"
  end
  %w[schema phase repo_scope skill_path confidence].each do |field|
    errors << "#{prefix}.#{field} must be a string when present" if entry.key?(field) && !entry[field].is_a?(String)
  end
  errors << "#{prefix}.evidence must be an object when present" if entry.key?("evidence") && !entry["evidence"].is_a?(Hash)
  errors
end

def valid_skill_feedback_targets
  A3::Domain::SkillFeedback.targets
end

def load_payload(result_path)
  return nil unless result_path.exist?

  raw = result_path.read
  return nil if raw.strip.empty?

  JSON.parse(raw)
end

def safe_log_component(value)
  value.to_s.gsub(/[^A-Za-z0-9._:-]/, "-")
end

def ai_raw_log_writer(request)
  root = public_env("A2O_AGENT_AI_RAW_LOG_ROOT", "A3_AGENT_AI_RAW_LOG_ROOT").to_s
  return nil if root.strip.empty?

  task_ref = safe_log_component(request["task_ref"])
  phase = safe_log_component(request["phase"])
  return nil if task_ref.empty? || phase.empty?

  path = Pathname(root).join(task_ref, "#{phase}.log")
  path.dirname.mkpath
  path.open("wb")
rescue StandardError
  nil
end

def capture_executor_output(command_env, command, stdin_bundle:, chdir:, request:)
  stdout = +""
  stderr = +""
  writer = ai_raw_log_writer(request)
  Open3.popen3(command_env, *command, chdir: chdir) do |stdin, out, err, wait_thr|
    stdin.write(stdin_bundle)
    stdin.close

    mutex = Mutex.new
    drain = lambda do |stream, buffer|
      Thread.new do
        loop do
          chunk = stream.readpartial(4096)
          mutex.synchronize do
            buffer << chunk
            writer&.write(chunk)
            writer&.flush
          end
        end
      rescue EOFError
      end
    end

    stdout_thread = drain.call(out, stdout)
    stderr_thread = drain.call(err, stderr)
    status = wait_thr.value
    stdout_thread.join
    stderr_thread.join
    [stdout, stderr, status]
  ensure
    writer&.close
  end
end

def main
  request_path = Pathname(public_env("A2O_WORKER_REQUEST_PATH", "A3_WORKER_REQUEST_PATH") || raise(KeyError, "A2O_WORKER_REQUEST_PATH is required"))
  result_path = Pathname(public_env("A2O_WORKER_RESULT_PATH", "A3_WORKER_RESULT_PATH") || raise(KeyError, "A2O_WORKER_RESULT_PATH is required"))
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
    stdout, stderr, status = capture_executor_output(
      { "PWD" => (public_env("A2O_WORKSPACE_ROOT", "A3_WORKSPACE_ROOT") || ROOT_DIR.to_s) }.merge(command_env),
      command,
      stdin_bundle: stdin_bundle,
      chdir: public_env("A2O_WORKSPACE_ROOT", "A3_WORKSPACE_ROOT") || ROOT_DIR.to_s,
      request: request
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
