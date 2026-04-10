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

  def upload_for(artifact_id, content)
    A3::Domain::AgentArtifactUpload.new(
      artifact_id: artifact_id,
      role: "combined-log",
      digest: "sha256:#{Digest::SHA256.hexdigest(content)}",
      byte_size: content.bytesize,
      retention_class: :diagnostic,
      media_type: "text/plain"
    )
  end
end
