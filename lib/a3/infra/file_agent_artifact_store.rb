# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

module A3
  module Infra
    class FileAgentArtifactStore
      SAFE_ARTIFACT_ID = /\A[A-Za-z0-9._:-]+\z/

      def initialize(root_dir)
        @root_dir = root_dir
      end

      def put(upload, content)
        content = content.to_s
        validate_artifact_id!(upload.artifact_id)
        validate_content!(upload, content)
        FileUtils.mkdir_p(storage_dir)

        if File.exist?(metadata_path(upload.artifact_id))
          existing = fetch_metadata(upload.artifact_id)
          return existing if existing == upload

          raise A3::Domain::ConfigurationError, "artifact_id already exists with different metadata: #{upload.artifact_id}"
        end

        atomic_write(blob_path(upload.artifact_id), content)
        atomic_write(metadata_path(upload.artifact_id), JSON.pretty_generate(upload.persisted_form))
        upload
      end

      def fetch_metadata(artifact_id)
        validate_artifact_id!(artifact_id)
        path = metadata_path(artifact_id)
        raise A3::Domain::RecordNotFound, "agent artifact not found: #{artifact_id}" unless File.exist?(path)

        A3::Domain::AgentArtifactUpload.from_persisted_form(JSON.parse(File.read(path)))
      end

      def read(artifact_id)
        validate_artifact_id!(artifact_id)
        path = blob_path(artifact_id)
        raise A3::Domain::RecordNotFound, "agent artifact content not found: #{artifact_id}" unless File.exist?(path)

        File.binread(path)
      end

      private

      def storage_dir
        File.join(@root_dir, "artifacts")
      end

      def metadata_path(artifact_id)
        File.join(storage_dir, "#{artifact_id}.json")
      end

      def blob_path(artifact_id)
        File.join(storage_dir, "#{artifact_id}.blob")
      end

      def validate_artifact_id!(artifact_id)
        return if artifact_id.to_s.match?(SAFE_ARTIFACT_ID)

        raise A3::Domain::ConfigurationError, "artifact_id contains unsafe characters: #{artifact_id.inspect}"
      end

      def validate_content!(upload, content)
        actual_byte_size = content.bytesize
        raise A3::Domain::ConfigurationError, "artifact byte_size mismatch for #{upload.artifact_id}: expected #{upload.byte_size}, got #{actual_byte_size}" unless actual_byte_size == upload.byte_size

        actual_digest = "sha256:#{Digest::SHA256.hexdigest(content)}"
        raise A3::Domain::ConfigurationError, "artifact digest mismatch for #{upload.artifact_id}: expected #{upload.digest}, got #{actual_digest}" unless upload.digest == actual_digest
      end

      def atomic_write(path, content)
        tmp_path = "#{path}.tmp-#{$$}-#{Thread.current.object_id}"
        File.binwrite(tmp_path, content)
        File.rename(tmp_path, path)
      ensure
        FileUtils.rm_f(tmp_path) if tmp_path && File.exist?(tmp_path)
      end
    end
  end
end
