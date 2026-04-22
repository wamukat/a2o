# frozen_string_literal: true

require "digest"
require "tmpdir"

RSpec.describe A3::CLI do
  it "reads one agent artifact from the configured storage dir" do
    Dir.mktmpdir do |dir|
      store = A3::Infra::FileAgentArtifactStore.new(File.join(dir, "agent_artifacts"))
      content = "raw ai executor log\nsecond line"
      upload = A3::Domain::AgentArtifactUpload.new(
        artifact_id: "worker-log",
        role: "combined-log",
        digest: "sha256:#{Digest::SHA256.hexdigest(content)}",
        byte_size: content.bytesize,
        retention_class: :diagnostic,
        media_type: "text/plain"
      )
      store.put(upload, content)

      out = StringIO.new
      described_class.start(
        [
          "agent-artifact-read",
          "--storage-dir", dir,
          "worker-log"
        ],
        out: out
      )

      expect(out.string).to eq("raw ai executor log\nsecond line\n")
    end
  end

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

  it "cleans agent artifacts by configured count and size caps" do
    Dir.mktmpdir do |dir|
      store = A3::Infra::FileAgentArtifactStore.new(File.join(dir, "agent_artifacts"))
      write_artifact(store, dir, "diagnostic-1", "111", Time.utc(2026, 4, 11, 8, 0, 0))
      write_artifact(store, dir, "diagnostic-2", "222", Time.utc(2026, 4, 11, 8, 1, 0))
      write_artifact(store, dir, "diagnostic-3", "333", Time.utc(2026, 4, 11, 8, 2, 0))

      out = StringIO.new
      described_class.start(
        [
          "agent-artifact-cleanup",
          "--storage-dir", dir,
          "--diagnostic-ttl-hours", "24",
          "--diagnostic-max-count", "2",
          "--diagnostic-max-mb", "0.000005"
        ],
        out: out
      )

      expect(out.string).to include("agent_artifact_cleanup=completed")
      expect(out.string).to include("deleted_count=3")
      expect { store.read("diagnostic-1") }.to raise_error(A3::Domain::RecordNotFound)
      expect { store.read("diagnostic-2") }.to raise_error(A3::Domain::RecordNotFound)
      expect { store.read("diagnostic-3") }.to raise_error(A3::Domain::RecordNotFound)
    end
  end

  it "retains analysis artifacts until an explicit analysis cleanup policy is configured" do
    Dir.mktmpdir do |dir|
      store = A3::Infra::FileAgentArtifactStore.new(File.join(dir, "agent_artifacts"))
      content = "analysis log"
      upload = A3::Domain::AgentArtifactUpload.new(
        artifact_id: "analysis-log",
        role: "ai-raw-log",
        digest: "sha256:#{Digest::SHA256.hexdigest(content)}",
        byte_size: content.bytesize,
        retention_class: :analysis,
        media_type: "text/plain"
      )
      store.put(upload, content)
      old_time = Time.now - (30 * 24 * 60 * 60)
      File.utime(
        old_time,
        old_time,
        File.join(dir, "agent_artifacts", "artifacts", "analysis-log.json"),
        File.join(dir, "agent_artifacts", "artifacts", "analysis-log.blob")
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

      expect(out.string).to include("deleted_count=0")
      expect(store.read("analysis-log")).to eq(content)
    end
  end

  def write_artifact(store, dir, artifact_id, content, timestamp)
    upload = A3::Domain::AgentArtifactUpload.new(
      artifact_id: artifact_id,
      role: "combined-log",
      digest: "sha256:#{Digest::SHA256.hexdigest(content)}",
      byte_size: content.bytesize,
      retention_class: :diagnostic,
      media_type: "text/plain"
    )
    store.put(upload, content)
    File.utime(
      timestamp,
      timestamp,
      File.join(dir, "agent_artifacts", "artifacts", "#{artifact_id}.json"),
      File.join(dir, "agent_artifacts", "artifacts", "#{artifact_id}.blob")
    )
  end
end
