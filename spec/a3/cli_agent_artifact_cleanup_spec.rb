# frozen_string_literal: true

require "digest"
require "tmpdir"

RSpec.describe A3::CLI do
  it "cleans expired agent artifacts from the configured storage dir" do
    Dir.mktmpdir do |dir|
      store = A3::Infra::FileAgentArtifactStore.new(File.join(dir, "agent_artifacts"))
      content = "old diagnostic log"
      upload = A3::Domain::AgentArtifactUpload.new(
        artifact_id: "diagnostic-log",
        role: "combined-log",
        digest: "sha256:#{Digest::SHA256.hexdigest(content)}",
        byte_size: content.bytesize,
        retention_class: :diagnostic,
        media_type: "text/plain"
      )
      store.put(upload, content)
      old_time = Time.now - (2 * 60 * 60)
      File.utime(
        old_time,
        old_time,
        File.join(dir, "agent_artifacts", "artifacts", "diagnostic-log.json"),
        File.join(dir, "agent_artifacts", "artifacts", "diagnostic-log.blob")
      )

      out = StringIO.new
      described_class.start(
        [
          "agent-artifact-cleanup",
          "--storage-dir", dir,
          "--diagnostic-ttl-hours", "1"
        ],
        out: out
      )

      expect(out.string).to include("agent_artifact_cleanup=completed")
      expect(out.string).to include("deleted_count=1")
      expect { store.read("diagnostic-log") }.to raise_error(A3::Domain::RecordNotFound)
    end
  end
end
