#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "digest"

request = JSON.parse(File.read(ENV.fetch("A2O_DECOMPOSITION_AUTHOR_REQUEST_PATH")))
evidence = request.fetch("investigation_evidence") || {}
source = evidence.fetch("request", {}).fetch("source_request", nil) || evidence.fetch("result", {}).fetch("source_request", nil) || {}
product = evidence.fetch("result", {}).fetch("product", {})
module_roles = product.fetch("module_roles", {})
title = source.fetch("title", "Requested product change")
description = source.fetch("description", "")

def role_summary(module_roles, key)
  role = module_roles.fetch(key, {})
  owns = Array(role["owns"])
  return "" if owns.empty?

  "Module role: #{key} owns #{owns.join('; ')}."
end

def canonicalize(value)
  case value
  when Hash
    value.keys.map(&:to_s).sort.each_with_object({}) do |key, memo|
      item = value.key?(key) ? value[key] : value[key.to_sym]
      memo[key] = canonicalize(item)
    end
  when Array
    value.map { |item| canonicalize(item) }
  else
    value
  end
end

def child_key_for(task_ref, boundary)
  Digest::SHA256.hexdigest(JSON.generate(canonicalize("source_ticket_ref" => task_ref, "boundary" => boundary.to_s)))[0, 24]
end

task_ref = request.fetch("task_ref")
contract_boundary = "API and module contract only; no production behavior change."
lib_boundary = "Production code and tests under utility-lib."
app_boundary = "Production code and tests under web-app."
verify_boundary = "Tests and verification only."
contract_key = child_key_for(task_ref, contract_boundary)
lib_key = child_key_for(task_ref, lib_boundary)
app_key = child_key_for(task_ref, app_boundary)

children = [
  {
    "title" => "Clarify API contract for #{title}",
    "body" => [
      "Define the externally visible behavior for the requested change.",
      "",
      role_summary(module_roles, "app"),
      role_summary(module_roles, "lib"),
      "",
      "Source requirement:",
      description
    ].join("\n"),
    "acceptance_criteria" => [
      "Endpoint, request, response, and error behavior are explicit.",
      "The contract identifies whether utility-lib behavior must change."
    ],
    "labels" => ["repo:app", "a2o:draft-child"],
    "depends_on" => [],
    "boundary" => contract_boundary,
    "rationale" => "The sample has separate utility and web modules, so the public contract should be agreed before implementation."
  },
  {
    "title" => "Implement greeting language rules for #{title} in utility-lib",
    "body" => [
      "Implement reusable greeting and language-selection behavior in utility-lib.",
      "",
      role_summary(module_roles, "lib"),
      "",
      "Source requirement:",
      description
    ].join("\n"),
    "acceptance_criteria" => [
      "utility-lib owns Japanese/English greeting message selection.",
      "utility-lib owns name normalization and reusable formatting rules.",
      "web-app behavior is not changed by this child except through the library contract."
    ],
    "labels" => ["repo:lib", "a2o:draft-child"],
    "depends_on" => [contract_key],
    "boundary" => lib_boundary,
    "rationale" => "Language-specific greeting behavior is reusable domain logic and should not be embedded in the web layer."
  },
  {
    "title" => "Expose #{title} through web-app UI and API",
    "body" => [
      "Expose the agreed greeting behavior through Spring MVC, HTML form, and HTMX partial updates.",
      "",
      role_summary(module_roles, "app"),
      "",
      "Source requirement:",
      description
    ].join("\n"),
    "acceptance_criteria" => [
      "web-app exposes language choice through the UI/API contract.",
      "web-app calls utility-lib for reusable greeting behavior.",
      "HTMX partial update renders the returned greeting without a full page reload."
    ],
    "labels" => ["repo:app", "a2o:draft-child"],
    "depends_on" => [contract_key, lib_key],
    "boundary" => app_boundary,
    "rationale" => "Browser-facing behavior belongs in web-app while greeting rules stay in utility-lib."
  },
  {
    "title" => "Verify #{title} behavior",
    "body" => [
      "Add focused automated tests for the requested behavior.",
      "",
      role_summary(module_roles, "app"),
      role_summary(module_roles, "lib"),
      "",
      "Source requirement:",
      description
    ].join("\n"),
    "acceptance_criteria" => [
      "Controller tests cover the HTTP response contract.",
      "web-app tests cover language parameter handling through the HTTP layer.",
      "utility-lib tests are covered by the utility-lib implementation child.",
      "`mvn test` passes from the sample project root."
    ],
    "labels" => ["repo:app", "a2o:draft-child"],
    "depends_on" => [lib_key, app_key],
    "boundary" => verify_boundary,
    "rationale" => "The sample is intended for observing A2O breakdown and execution, so tests should make the target behavior visible."
  }
]

result = {
  "outcome" => "draft_children",
  "refactoring_assessment" => {
    "disposition" => "defer_follow_up",
    "reason" => "Greeting formatting and locale fallback rules should stay reusable in utility-lib rather than being duplicated in web-app.",
    "scope" => ["utility-lib", "web-app"],
    "recommended_action" => "create_follow_up_child",
    "risk" => "low",
    "evidence" => [
      "utility-lib owns reusable greeting behavior.",
      "web-app should expose behavior through HTTP/UI only."
    ]
  },
  "parent" => {
    "title" => "Implementation plan for #{title}",
    "body" => [
      "## Feature overview",
      description.empty? ? "Implement the requested sample application change." : description,
      "",
      "## Module split",
      role_summary(module_roles, "app"),
      role_summary(module_roles, "lib"),
      "",
      "## Overall acceptance criteria",
      "- Generated child tickets complete the contract, utility-lib, web-app, and verification work.",
      "- The sample passes `mvn test` from the project root."
    ].reject(&:empty?).join("\n")
  },
  "children" => children,
  "unresolved_questions" => []
}

File.write(ENV.fetch("A2O_DECOMPOSITION_AUTHOR_RESULT_PATH"), "#{JSON.pretty_generate(result)}\n")
