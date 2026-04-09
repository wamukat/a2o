# frozen_string_literal: true

require "spec_helper"

RSpec.describe A3::Application::BuildWorkerTaskPacket do
  let(:task) do
    A3::Domain::Task.new(
      ref: "Sample#3153",
      kind: :single,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      parent_ref: nil,
      child_refs: [],
      external_task_id: 3153
    )
  end

  it "builds a worker task packet from the external task snapshot" do
    external_task_source = instance_double("ExternalTaskSource")
    allow(external_task_source).to receive(:fetch_task_packet_by_external_task_id).with(3153).and_return(
      {
        "task_id" => 3153,
        "ref" => "Sample#3153",
        "title" => "Migrate persistence from JDBC to MyBatis",
        "description" => "Replace the JDBC implementation with a MyBatis-backed one.",
        "status" => "In progress",
        "labels" => %w[repo:alpha trigger:auto-implement],
        "parent_ref" => nil
      }
    )

    packet = described_class.new(external_task_source: external_task_source).call(task: task)

    expect(packet.request_form).to include(
      "ref" => "Sample#3153",
      "external_task_id" => 3153,
      "kind" => "single",
      "title" => "Migrate persistence from JDBC to MyBatis",
      "description" => "Replace the JDBC implementation with a MyBatis-backed one.",
      "status" => "In progress",
      "labels" => %w[repo:alpha trigger:auto-implement],
      "edit_scope" => ["repo_alpha"],
      "verification_scope" => ["repo_alpha"]
    )
  end

  it "fails closed when an external task exists but the task packet is unavailable" do
    external_task_source = instance_double("ExternalTaskSource")
    allow(external_task_source).to receive(:fetch_task_packet_by_external_task_id).with(3153).and_return(nil)

    expect do
      described_class.new(external_task_source: external_task_source).call(task: task)
    end.to raise_error(A3::Domain::ConfigurationError, /missing external task packet/)
  end

  it "fails closed when the task has no external id and the source cannot resolve by ref" do
    internal_task = A3::Domain::Task.new(
      ref: "Sample#9999",
      kind: :single,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha]
    )
    external_task_source = instance_double("ExternalTaskSource")
    allow(external_task_source).to receive(:fetch_task_packet_by_ref).with("Sample#9999").and_return(nil)

    expect do
      described_class.new(external_task_source: external_task_source).call(task: internal_task)
    end.to raise_error(A3::Domain::ConfigurationError, /missing external task packet/)
  end
end
