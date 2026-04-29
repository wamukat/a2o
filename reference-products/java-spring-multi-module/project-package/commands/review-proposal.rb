#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

request = JSON.parse(File.read(ENV.fetch("A2O_DECOMPOSITION_REVIEW_REQUEST_PATH")))
proposal = request.dig("proposal_evidence", "proposal") || {}
children = proposal.fetch("children", [])

findings = []
findings << {
  "severity" => "critical",
  "summary" => "proposal must create at least one child ticket",
  "details" => "No child drafts were found in the proposal evidence."
} if children.empty?

children.each_with_index do |child, index|
  labels = Array(child["labels"])
  repo_labels = labels & ["repo:app", "repo:lib"]
  next if repo_labels.length == 1

  findings << {
    "severity" => "critical",
    "summary" => "child #{index + 1} must target exactly one repo scope",
    "details" => "Draft children in this sample must target exactly one of repo:app or repo:lib."
  }
end

result = {
  "summary" => findings.empty? ? "Proposal is eligible for draft child creation." : "Proposal is blocked by review findings.",
  "findings" => findings
}

File.write(ENV.fetch("A2O_DECOMPOSITION_REVIEW_RESULT_PATH"), "#{JSON.pretty_generate(result)}\n")
