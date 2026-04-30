# frozen_string_literal: true

require "open3"

RSpec.describe A3::Infra::KanbanCliFollowUpChildWriter do
  subject(:writer) do
    described_class.new(
      command_argv: %w[task kanban:api --],
      project: "Sample",
      repo_label_map: { "repo:starters" => ["repo_alpha"], "repo:ui-app" => ["repo_beta"] },
      follow_up_label: "a2o:follow-up-child",
      working_dir: "/tmp"
    )
  end

  let(:success_status) { instance_double(Process::Status, success?: true, exitstatus: 0) }

  let(:disposition) do
    A3::Domain::ReviewDisposition.new(
      kind: :follow_up_child,
      slot_scopes: [:repo_beta],
      summary: "redirect regression",
      description: "legacy malformed params should redirect",
      finding_key: "finding-1"
    )
  end

  it "creates a new follow-up child and attaches it to the parent" do
    description = <<~DESC.strip
      Parent: Sample#3140
      Repo scope: repo_beta
      Fingerprint: Sample#3140|run-parent-review-1|repo_beta|finding-1

      Summary:
      redirect regression

      Details:
      legacy malformed params should redirect
    DESC
    captured_argv = []
    responses = [
      ["[]", "", success_status], # task-find
      [JSON.generate({ "id" => 3200, "ref" => "Sample#3200", "title" => "Follow-up for Sample#3140 (repo_beta): redirect regression", "description" => description }), "", success_status],
      ["{}", "", success_status], # label-ensure repo
      ["{}", "", success_status], # label-add repo
      ["{}", "", success_status], # label-ensure trigger
      ["{}", "", success_status], # label-add trigger
      ["{}", "", success_status], # label-ensure follow-up
      ["{}", "", success_status], # label-add follow-up
      ["[]", "", success_status], # relation list
      ["{}", "", success_status] # relation create
    ]
    allow(Open3).to receive(:capture3) do |*args|
      captured_argv << args
      responses.shift
    end

    result = writer.call(
      parent_task_ref: "Sample#3140",
      parent_external_task_id: 3140,
      review_run_ref: "run-parent-review-1",
      disposition: disposition
    )

    expect(result.success?).to be(true)
    expect(result.child_refs).to eq(["Sample#3200"])
    expect(result.child_fingerprints).to eq(["Sample#3140|run-parent-review-1|repo_beta|finding-1"])
    task_create_argv = captured_argv.find { |args| args.include?("task-create") }
    expect(task_create_argv).to include("--priority", "2")
    expect(task_create_argv).to include("--description-file")
    expect(task_create_argv).not_to include("--description")
  end

  it "blocks when an existing fingerprinted child has mismatched canonical payload" do
    allow(Open3).to receive(:capture3).and_return(
      [JSON.generate([{ "id" => 3200, "ref" => "Sample#3200", "title" => "wrong", "description" => "Fingerprint: Sample#3140|run-parent-review-1|repo_beta|finding-1" }]), "", success_status]
    )

    result = writer.call(
      parent_task_ref: "Sample#3140",
      parent_external_task_id: 3140,
      review_run_ref: "run-parent-review-1",
      disposition: disposition
    )

    expect(result.success?).to be(false)
    expect(result.summary).to eq("follow-up child creation failed")
  end

  it "blocks when an existing fingerprinted child has relation drift" do
    description = <<~DESC.strip
      Parent: Sample#3140
      Repo scope: repo_beta
      Fingerprint: Sample#3140|run-parent-review-1|repo_beta|finding-1

      Summary:
      redirect regression

      Details:
      legacy malformed params should redirect
    DESC
    allow(Open3).to receive(:capture3).and_return(
      [JSON.generate([{ "id" => 3200, "ref" => "Sample#3200", "title" => "Follow-up for Sample#3140 (repo_beta): redirect regression", "description" => description }]), "", success_status],
      [JSON.generate([{ "title" => "a3:follow-up-child" }, { "title" => "repo:ui-app" }, { "title" => "trigger:auto-implement" }]), "", success_status],
      ["[]", "", success_status]
    )

    result = writer.call(
      parent_task_ref: "Sample#3140",
      parent_external_task_id: 3140,
      review_run_ref: "run-parent-review-1",
      disposition: disposition
    )

    expect(result.success?).to be(false)
    expect(result.summary).to eq("follow-up child creation failed")
  end

  it "blocks when an existing child only has the legacy follow-up label" do
    description = <<~DESC.strip
      Parent: Sample#3140
      Repo scope: repo_beta
      Fingerprint: Sample#3140|run-parent-review-1|repo_beta|finding-1

      Summary:
      redirect regression

      Details:
      legacy malformed params should redirect
    DESC
    responses = [
      [JSON.generate([{ "id" => 3200, "ref" => "Sample#3200", "title" => "Follow-up for Sample#3140 (repo_beta): redirect regression", "description" => description }]), "", success_status],
      [JSON.generate([{ "title" => "a3:follow-up-child" }, { "title" => "repo:ui-app" }, { "title" => "trigger:auto-implement" }]), "", success_status],
      [JSON.generate({ "subtask" => [{ "id" => 3200 }] }), "", success_status]
    ]
    allow(Open3).to receive(:capture3).and_return(*responses)

    result = writer.call(
      parent_task_ref: "Sample#3140",
      parent_external_task_id: 3140,
      review_run_ref: "run-parent-review-1",
      disposition: disposition
    )

    expect(result.success?).to be(false)
    expect(result.summary).to eq("follow-up child creation failed")
  end

  it "blocks when an existing child mixes legacy and public follow-up labels" do
    description = <<~DESC.strip
      Parent: Sample#3140
      Repo scope: repo_beta
      Fingerprint: Sample#3140|run-parent-review-1|repo_beta|finding-1

      Summary:
      redirect regression

      Details:
      legacy malformed params should redirect
    DESC
    responses = [
      [JSON.generate([{ "id" => 3200, "ref" => "Sample#3200", "title" => "Follow-up for Sample#3140 (repo_beta): redirect regression", "description" => description }]), "", success_status],
      [JSON.generate([{ "title" => "a2o:follow-up-child" }, { "title" => "a3:follow-up-child" }, { "title" => "repo:ui-app" }, { "title" => "trigger:auto-implement" }]), "", success_status],
      [JSON.generate({ "subtask" => [{ "id" => 3200 }] }), "", success_status]
    ]
    allow(Open3).to receive(:capture3).and_return(*responses)

    result = writer.call(
      parent_task_ref: "Sample#3140",
      parent_external_task_id: 3140,
      review_run_ref: "run-parent-review-1",
      disposition: disposition
    )

    expect(result.success?).to be(false)
    expect(result.summary).to eq("follow-up child creation failed")
  end

  it "fails closed when no repo label is configured for the disposition scope" do
    writer = described_class.new(
      command_argv: %w[task kanban:api --],
      project: "Sample",
      repo_label_map: { "repo:starters" => ["repo_alpha"] },
      follow_up_label: "a2o:follow-up-child",
      working_dir: "/tmp"
    )
    allow(Open3).to receive(:capture3).and_return(
      ["[]", "", success_status] # task-find
    )

    result = writer.call(
      parent_task_ref: "Sample#3140",
      parent_external_task_id: 3140,
      review_run_ref: "run-parent-review-1",
      disposition: disposition
    )

    expect(result.success?).to be(false)
    expect(result.summary).to eq("follow-up child creation failed")
    expect(result.diagnostics.fetch("error")).to include("missing kanban repo label")
  end
end
