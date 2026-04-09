# frozen_string_literal: true

require "open3"

RSpec.describe A3::Infra::KanbanCliFollowUpChildWriter do
  subject(:writer) do
    described_class.new(
      command_argv: %w[task kanban:api --],
      project: "Portal",
      working_dir: "/tmp"
    )
  end

  let(:success_status) { instance_double(Process::Status, success?: true, exitstatus: 0) }

  let(:disposition) do
    A3::Domain::ReviewDisposition.new(
      kind: :follow_up_child,
      repo_scope: :repo_beta,
      summary: "redirect regression",
      description: "legacy malformed params should redirect",
      finding_key: "finding-1"
    )
  end

  it "creates a new follow-up child and attaches it to the parent" do
    description = <<~DESC.strip
      Parent: Portal#3140
      Repo scope: repo_beta
      Fingerprint: Portal#3140|run-parent-review-1|repo_beta|finding-1

      Summary:
      redirect regression

      Details:
      legacy malformed params should redirect
    DESC
    allow(Open3).to receive(:capture3).and_return(
      ["[]", "", success_status], # task-find
      [JSON.generate({ "id" => 3200, "ref" => "Portal#3200", "title" => "Follow-up for Portal#3140 (repo_beta): redirect regression", "description" => description }), "", success_status],
      ["{}", "", success_status], # label-ensure repo
      ["{}", "", success_status], # label-add repo
      ["{}", "", success_status], # label-ensure trigger
      ["{}", "", success_status], # label-add trigger
      ["{}", "", success_status], # label-ensure follow-up
      ["{}", "", success_status], # label-add follow-up
      ["[]", "", success_status], # relation list
      ["{}", "", success_status] # relation create
    )

    result = writer.call(
      parent_task_ref: "Portal#3140",
      parent_external_task_id: 3140,
      review_run_ref: "run-parent-review-1",
      disposition: disposition
    )

    expect(result.success?).to be(true)
    expect(result.child_refs).to eq(["Portal#3200"])
    expect(result.child_fingerprints).to eq(["Portal#3140|run-parent-review-1|repo_beta|finding-1"])
  end

  it "blocks when an existing fingerprinted child has mismatched canonical payload" do
    allow(Open3).to receive(:capture3).and_return(
      [JSON.generate([{ "id" => 3200, "ref" => "Portal#3200", "title" => "wrong", "description" => "Fingerprint: Portal#3140|run-parent-review-1|repo_beta|finding-1" }]), "", success_status]
    )

    result = writer.call(
      parent_task_ref: "Portal#3140",
      parent_external_task_id: 3140,
      review_run_ref: "run-parent-review-1",
      disposition: disposition
    )

    expect(result.success?).to be(false)
    expect(result.summary).to eq("follow-up child creation failed")
  end

  it "blocks when an existing fingerprinted child has relation drift" do
    description = <<~DESC.strip
      Parent: Portal#3140
      Repo scope: repo_beta
      Fingerprint: Portal#3140|run-parent-review-1|repo_beta|finding-1

      Summary:
      redirect regression

      Details:
      legacy malformed params should redirect
    DESC
    allow(Open3).to receive(:capture3).and_return(
      [JSON.generate([{ "id" => 3200, "ref" => "Portal#3200", "title" => "Follow-up for Portal#3140 (repo_beta): redirect regression", "description" => description }]), "", success_status],
      [JSON.generate([{ "title" => "a3-v2:follow-up-child" }, { "title" => "repo:ui-app" }, { "title" => "trigger:auto-implement" }]), "", success_status],
      ["[]", "", success_status]
    )

    result = writer.call(
      parent_task_ref: "Portal#3140",
      parent_external_task_id: 3140,
      review_run_ref: "run-parent-review-1",
      disposition: disposition
    )

    expect(result.success?).to be(false)
    expect(result.summary).to eq("follow-up child creation failed")
  end
end
