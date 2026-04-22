# frozen_string_literal: true

require "digest"
require "tmpdir"

RSpec.describe A3::CLI do
  def upload_record(artifact_id:, role:, content:, retention_class: "analysis", media_type: "text/plain")
    {
      "artifact_id" => artifact_id,
      "role" => role,
      "digest" => "sha256:#{Digest::SHA256.hexdigest(content)}",
      "byte_size" => content.bytesize,
      "retention_class" => retention_class,
      "media_type" => media_type
    }
  end

  def write_run(storage_dir:, task_ref:, run_ref:, phase:, log_uploads:, artifact_uploads: [])
    task = A3::Domain::Task.new(
      ref: task_ref,
      kind: :single,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :done
    )
    execution = A3::Domain::PhaseExecutionRecord.new(
      summary: "completed",
      diagnostics: {
        "agent_job_result" => {
          "log_uploads" => log_uploads,
          "artifact_uploads" => artifact_uploads
        }
      }
    )
    source_descriptor = A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: task_ref, ref: "abc123")
    scope_snapshot = A3::Domain::ScopeSnapshot.new(edit_scope: [:repo_alpha], verification_scope: [:repo_alpha], ownership_scope: :task)
    artifact_owner = A3::Domain::ArtifactOwner.new(owner_ref: task_ref, owner_scope: :task, snapshot_version: "abc123")
    run = A3::Domain::Run.new(
      ref: run_ref,
      task_ref: task_ref,
      phase: phase,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor,
      scope_snapshot: scope_snapshot,
      artifact_owner: artifact_owner
    ).append_phase_evidence(
      phase: phase,
      source_descriptor: source_descriptor,
      scope_snapshot: scope_snapshot,
      execution_record: execution
    ).complete(outcome: :completed)

    A3::Infra::JsonTaskRepository.new(File.join(storage_dir, "tasks.json")).save(task)
    A3::Infra::JsonRunRepository.new(File.join(storage_dir, "runs.json")).save(run)
  end

  it "selects runtime log artifacts by task in dry-run mode" do
    Dir.mktmpdir do |dir|
      store = A3::Infra::FileAgentArtifactStore.new(File.join(dir, "agent_artifacts"))
      content = "log body"
      upload = A3::Domain::AgentArtifactUpload.new(
        artifact_id: "run-1-combined-log",
        role: "combined-log",
        digest: "sha256:#{Digest::SHA256.hexdigest(content)}",
        byte_size: content.bytesize,
        retention_class: :analysis,
        media_type: "text/plain"
      )
      store.put(upload, content)
      write_run(
        storage_dir: dir,
        task_ref: "A2O#149",
        run_ref: "run-1",
        phase: :implementation,
        log_uploads: [upload_record(artifact_id: "run-1-combined-log", role: "combined-log", content: content)]
      )

      out = StringIO.new
      described_class.start(
        ["clear-runtime-logs", "--storage-dir", dir, "--task-ref", "A2O#149"],
        out: out
      )

      expect(out.string).to include("runtime_log_clear=dry_run")
      expect(out.string).to include("selected_count=1")
      expect(store.read("run-1-combined-log")).to eq(content)
    end
  end

  it "deletes selected runtime log artifacts when --apply is set" do
    Dir.mktmpdir do |dir|
      store = A3::Infra::FileAgentArtifactStore.new(File.join(dir, "agent_artifacts"))
      content = "log body"
      upload = A3::Domain::AgentArtifactUpload.new(
        artifact_id: "run-2-combined-log",
        role: "combined-log",
        digest: "sha256:#{Digest::SHA256.hexdigest(content)}",
        byte_size: content.bytesize,
        retention_class: :analysis,
        media_type: "text/plain"
      )
      store.put(upload, content)
      write_run(
        storage_dir: dir,
        task_ref: "A2O#148",
        run_ref: "run-2",
        phase: :verification,
        log_uploads: [upload_record(artifact_id: "run-2-combined-log", role: "combined-log", content: content)]
      )

      out = StringIO.new
      described_class.start(
        ["clear-runtime-logs", "--storage-dir", dir, "--run-ref", "run-2", "--apply"],
        out: out
      )

      expect(out.string).to include("runtime_log_clear=completed")
      expect(out.string).to include("deleted_count=1")
      expect { store.read("run-2-combined-log") }.to raise_error(A3::Domain::RecordNotFound)
    end
  end

  it "clears ai raw and execution metadata artifacts through --all-analysis" do
    Dir.mktmpdir do |dir|
      store = A3::Infra::FileAgentArtifactStore.new(File.join(dir, "agent_artifacts"))
      ai_raw_content = "assistant is thinking"
      metadata_content = "{\"duration_seconds\": 12.5}\n"
      ai_raw_upload = A3::Domain::AgentArtifactUpload.new(
        artifact_id: "run-3-ai-raw-log",
        role: "ai-raw-log",
        digest: "sha256:#{Digest::SHA256.hexdigest(ai_raw_content)}",
        byte_size: ai_raw_content.bytesize,
        retention_class: :analysis,
        media_type: "text/plain"
      )
      metadata_upload = A3::Domain::AgentArtifactUpload.new(
        artifact_id: "run-3-execution-metadata",
        role: "execution-metadata",
        digest: "sha256:#{Digest::SHA256.hexdigest(metadata_content)}",
        byte_size: metadata_content.bytesize,
        retention_class: :analysis,
        media_type: "application/json"
      )
      store.put(ai_raw_upload, ai_raw_content)
      store.put(metadata_upload, metadata_content)
      write_run(
        storage_dir: dir,
        task_ref: "A2O#149",
        run_ref: "run-3",
        phase: :implementation,
        log_uploads: [upload_record(artifact_id: "run-3-ai-raw-log", role: "ai-raw-log", content: ai_raw_content)],
        artifact_uploads: [upload_record(artifact_id: "run-3-execution-metadata", role: "execution-metadata", content: metadata_content, media_type: "application/json")]
      )

      out = StringIO.new
      described_class.start(
        ["clear-runtime-logs", "--storage-dir", dir, "--all-analysis", "--apply"],
        out: out
      )

      expect(out.string).to include("runtime_log_clear=completed")
      expect(out.string).to include("selected_count=2")
      expect { store.read("run-3-ai-raw-log") }.to raise_error(A3::Domain::RecordNotFound)
      expect { store.read("run-3-execution-metadata") }.to raise_error(A3::Domain::RecordNotFound)
    end
  end
end
