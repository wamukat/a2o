# frozen_string_literal: true

require "digest"
require "spec_helper"

RSpec.describe A3::Infra::FileAgentArtifactStore do
  let(:tmpdir) { Dir.mktmpdir }
  let(:store) { described_class.new(tmpdir) }

  after do
    FileUtils.rm_rf(tmpdir)
  end

  it "stores artifact content and upload metadata by A3-managed artifact id" do
    content = "verification log\n"
    upload = upload_for("art-log-1", content)

    stored = store.put(upload, content)

    expect(stored).to eq(upload)
    expect(store.fetch_metadata("art-log-1")).to eq(upload)
    expect(store.read("art-log-1")).to eq(content)
  end

  it "rejects digest mismatches" do
    upload = A3::Domain::AgentArtifactUpload.new(
      artifact_id: "art-log-1",
      role: "combined-log",
      digest: "sha256:deadbeef",
      byte_size: 4,
      retention_class: :diagnostic
    )

    expect do
      store.put(upload, "data")
    end.to raise_error(A3::Domain::ConfigurationError, /digest mismatch/)
  end

  it "rejects unsafe artifact ids" do
    content = "log"
    upload = upload_for("../log", content)

    expect do
      store.put(upload, content)
    end.to raise_error(A3::Domain::ConfigurationError, /unsafe/)
  end

  it "cleans up expired artifacts by retention class" do
    diagnostic = upload_for("diagnostic-log", "old diagnostic", retention_class: :diagnostic)
    evidence = upload_for("evidence-log", "old evidence", retention_class: :evidence)
    store.put(diagnostic, "old diagnostic")
    store.put(evidence, "old evidence")
    old_time = Time.utc(2026, 4, 11, 8, 0, 0)
    File.utime(old_time, old_time, artifact_file("diagnostic-log", "json"), artifact_file("diagnostic-log", "blob"))
    File.utime(old_time, old_time, artifact_file("evidence-log", "json"), artifact_file("evidence-log", "blob"))

    result = store.cleanup(
      retention_seconds_by_class: {diagnostic: 60, evidence: 3600},
      now: Time.utc(2026, 4, 11, 8, 2, 0)
    )

    expect(result.deleted_artifact_ids).to eq(["diagnostic-log"])
    expect(result.retained_artifact_ids).to eq(["evidence-log"])
    expect { store.read("diagnostic-log") }.to raise_error(A3::Domain::RecordNotFound)
    expect(store.read("evidence-log")).to eq("old evidence")
  end

  it "reports cleanup candidates without deleting in dry-run mode" do
    store.put(upload_for("diagnostic-log", "old diagnostic"), "old diagnostic")
    old_time = Time.utc(2026, 4, 11, 8, 0, 0)
    File.utime(old_time, old_time, artifact_file("diagnostic-log", "json"), artifact_file("diagnostic-log", "blob"))

    result = store.cleanup(
      retention_seconds_by_class: {diagnostic: 60},
      now: Time.utc(2026, 4, 11, 8, 2, 0),
      dry_run: true
    )

    expect(result).to have_attributes(deleted_artifact_ids: ["diagnostic-log"], dry_run: true)
    expect(store.read("diagnostic-log")).to eq("old diagnostic")
  end

  it "caps retained artifacts by count per retention class" do
    write_artifact("diagnostic-1", "one", timestamp: Time.utc(2026, 4, 11, 8, 0, 0))
    write_artifact("diagnostic-2", "two", timestamp: Time.utc(2026, 4, 11, 8, 1, 0))
    write_artifact("diagnostic-3", "three", timestamp: Time.utc(2026, 4, 11, 8, 2, 0))

    result = store.cleanup(
      retention_seconds_by_class: {diagnostic: 24 * 60 * 60},
      max_count_by_class: {diagnostic: 2},
      now: Time.utc(2026, 4, 11, 8, 3, 0)
    )

    expect(result.deleted_artifact_ids).to eq(["diagnostic-1"])
    expect(result.retained_artifact_ids).to contain_exactly("diagnostic-2", "diagnostic-3")
    expect { store.read("diagnostic-1") }.to raise_error(A3::Domain::RecordNotFound)
  end

  it "caps retained artifacts by total bytes per retention class" do
    write_artifact("diagnostic-1", "111", timestamp: Time.utc(2026, 4, 11, 8, 0, 0))
    write_artifact("diagnostic-2", "222", timestamp: Time.utc(2026, 4, 11, 8, 1, 0))
    write_artifact("diagnostic-3", "333", timestamp: Time.utc(2026, 4, 11, 8, 2, 0))

    result = store.cleanup(
      retention_seconds_by_class: {diagnostic: 24 * 60 * 60},
      max_bytes_by_class: {diagnostic: 5},
      now: Time.utc(2026, 4, 11, 8, 3, 0)
    )

    expect(result.deleted_artifact_ids).to eq(%w[diagnostic-1 diagnostic-2])
    expect(result.retained_artifact_ids).to eq(["diagnostic-3"])
    expect(store.read("diagnostic-3")).to eq("333")
  end

  it "reports count and byte cap cleanup candidates without deleting in dry-run mode" do
    write_artifact("diagnostic-1", "111", timestamp: Time.utc(2026, 4, 11, 8, 0, 0))
    write_artifact("diagnostic-2", "222", timestamp: Time.utc(2026, 4, 11, 8, 1, 0))

    result = store.cleanup(
      retention_seconds_by_class: {diagnostic: 24 * 60 * 60},
      max_count_by_class: {diagnostic: 1},
      max_bytes_by_class: {diagnostic: 2},
      now: Time.utc(2026, 4, 11, 8, 2, 0),
      dry_run: true
    )

    expect(result).to have_attributes(deleted_artifact_ids: %w[diagnostic-1 diagnostic-2], dry_run: true)
    expect(store.read("diagnostic-1")).to eq("111")
    expect(store.read("diagnostic-2")).to eq("222")
  end

  def upload_for(artifact_id, content, retention_class: :diagnostic)
    A3::Domain::AgentArtifactUpload.new(
      artifact_id: artifact_id,
      role: "combined-log",
      digest: "sha256:#{Digest::SHA256.hexdigest(content)}",
      byte_size: content.bytesize,
      retention_class: retention_class,
      media_type: "text/plain"
    )
  end

  def artifact_file(artifact_id, extension)
    File.join(tmpdir, "artifacts", "#{artifact_id}.#{extension}")
  end

  def write_artifact(artifact_id, content, retention_class: :diagnostic, timestamp:)
    store.put(upload_for(artifact_id, content, retention_class: retention_class), content)
    File.utime(timestamp, timestamp, artifact_file(artifact_id, "json"), artifact_file(artifact_id, "blob"))
  end
end
