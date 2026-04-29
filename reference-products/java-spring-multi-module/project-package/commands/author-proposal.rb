#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

request = JSON.parse(File.read(ENV.fetch("A2O_DECOMPOSITION_AUTHOR_REQUEST_PATH")))
evidence = request.fetch("investigation_evidence") || {}
source = evidence.fetch("request", {}).fetch("source_request", nil) || evidence.fetch("result", {}).fetch("source_request", nil) || {}
title = source.fetch("title", "Requested product change")
description = source.fetch("description", "")

children = [
  {
    "title" => "Clarify API contract for #{title}",
    "body" => [
      "Define the externally visible behavior for the requested change.",
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
    "boundary" => "API and module contract only; no production behavior change.",
    "rationale" => "The sample has separate utility and web modules, so the public contract should be agreed before implementation."
  },
  {
    "title" => "Implement #{title} in utility-lib and web-app",
    "body" => [
      "Implement the agreed behavior in the Java Spring sample.",
      "",
      "Source requirement:",
      description
    ].join("\n"),
    "acceptance_criteria" => [
      "utility-lib owns reusable formatting or domain logic.",
      "web-app exposes the behavior through Spring MVC.",
      "Existing health and greeting behavior remains compatible unless explicitly changed."
    ],
    "labels" => ["repo:app", "a2o:draft-child"],
    "depends_on" => [],
    "boundary" => "Production code in utility-lib and web-app.",
    "rationale" => "The requested behavior likely crosses the library/application boundary."
  },
  {
    "title" => "Verify #{title} behavior",
    "body" => [
      "Add focused automated tests for the requested behavior.",
      "",
      "Source requirement:",
      description
    ].join("\n"),
    "acceptance_criteria" => [
      "Controller tests cover the HTTP response contract.",
      "Utility tests cover reusable formatting or normalization rules.",
      "`mvn test` passes from the sample project root."
    ],
    "labels" => ["repo:app", "a2o:draft-child"],
    "depends_on" => [],
    "boundary" => "Tests and verification only.",
    "rationale" => "The sample is intended for observing A2O breakdown and execution, so tests should make the target behavior visible."
  }
]

result = {
  "children" => children,
  "unresolved_questions" => []
}

File.write(ENV.fetch("A2O_DECOMPOSITION_AUTHOR_RESULT_PATH"), "#{JSON.pretty_generate(result)}\n")
