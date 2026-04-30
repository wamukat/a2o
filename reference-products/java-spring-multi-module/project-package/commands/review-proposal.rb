#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

request = JSON.parse(File.read(ENV.fetch("A2O_DECOMPOSITION_REVIEW_REQUEST_PATH")))
proposal = request.dig("proposal_evidence", "proposal") || {}
outcome = proposal.fetch("outcome", "draft_children").to_s
children = proposal.fetch("children", [])

findings = []
unless %w[draft_children no_action needs_clarification].include?(outcome)
  findings << {
    "severity" => "critical",
    "summary" => "proposal outcome is not supported",
    "details" => "Use draft_children, no_action, or needs_clarification."
  }
end

findings << {
  "severity" => "critical",
  "summary" => "proposal must create at least one child ticket",
  "details" => "No child drafts were found in the proposal evidence."
} if outcome == "draft_children" && children.empty?

if %w[no_action needs_clarification].include?(outcome) && children.any?
  findings << {
    "severity" => "critical",
    "summary" => "proposal outcome must not include child drafts",
    "details" => "#{outcome} proposals should leave children empty and explain the result on the source ticket."
  }
end

if %w[no_action needs_clarification].include?(outcome) && proposal.fetch("reason", "").to_s.strip.empty?
  findings << {
    "severity" => "critical",
    "summary" => "proposal outcome requires a reason",
    "details" => "#{outcome} proposals need a concise reason for the source-ticket audit comment."
  }
end

if outcome == "needs_clarification" && Array(proposal["questions"]).empty?
  findings << {
    "severity" => "critical",
    "summary" => "clarification proposal requires questions",
    "details" => "Ask at least one concrete question for the requirement owner."
  }
end

assessment = proposal["refactoring_assessment"]
if assessment
  unless assessment.is_a?(Hash) && %w[none include_child defer_follow_up blocked_by_design_debt needs_clarification].include?(assessment["disposition"])
    findings << {
      "severity" => "critical",
      "summary" => "refactoring assessment disposition is invalid",
      "details" => "Use none, include_child, defer_follow_up, blocked_by_design_debt, or needs_clarification."
    }
  end
end

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
