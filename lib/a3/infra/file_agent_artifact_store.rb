# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

module A3
  module Infra
    class FileAgentArtifactStore
      SAFE_ARTIFACT_ID = /\A[A-Za-z0-9._:-]+\z/
      CleanupResult = Struct.new(:deleted_artifact_ids, :retained_artifact_ids, :missing_blob_artifact_ids, :dry_run, keyword_init: true) do
        def deleted_count
          deleted_artifact_ids.size
        end

        def retained_count
          retained_artifact_ids.size
        end

        def missing_blob_count
          missing_blob_artifact_ids.size
        end
      end

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

      def list_metadata
        return [] unless Dir.exist?(storage_dir)

        metadata_paths.filter_map do |path|
          artifact_id = artifact_id_from_metadata_path(path)
          fetch_metadata(artifact_id)
        rescue A3::Domain::ConfigurationError, JSON::ParserError
          nil
        end
      end

      def delete_many(artifact_ids, dry_run: false)
        deleted = []
        missing = []
        Array(artifact_ids).map(&:to_s).uniq.each do |artifact_id|
          validate_artifact_id!(artifact_id)
          metadata = metadata_path(artifact_id)
          blob = blob_path(artifact_id)
          if !File.exist?(metadata) && !File.exist?(blob)
            missing << artifact_id
            next
          end
          deleted << artifact_id
          delete_artifact_files(metadata, blob) unless dry_run
        end
        { deleted_artifact_ids: deleted, missing_artifact_ids: missing, dry_run: dry_run }
      end

      def cleanup(retention_seconds_by_class:, max_count_by_class: {}, max_bytes_by_class: {}, now: Time.now, dry_run: false)
        deleted = []
        retained = []
        missing_blob = []
        retained_records = []
        return CleanupResult.new(deleted_artifact_ids: deleted, retained_artifact_ids: retained, missing_blob_artifact_ids: missing_blob, dry_run: dry_run) unless Dir.exist?(storage_dir)

        metadata_paths.each do |path|
          artifact_id = artifact_id_from_metadata_path(path)
          upload = fetch_metadata(artifact_id)
          blob = blob_path(artifact_id)
          missing_blob << artifact_id unless File.exist?(blob)

          ttl = retention_seconds_by_class.fetch(upload.retention_class.to_sym, nil)
          if ttl && expired?(path, blob, now: now, ttl: ttl)
            deleted << artifact_id
            delete_artifact_files(path, blob) unless dry_run
          else
            retained << artifact_id
            retained_records << {
              artifact_id: artifact_id,
              metadata: path,
              blob: blob,
              retention_class: upload.retention_class.to_sym,
              byte_size: upload.byte_size,
              mtime: newest_mtime(path, blob)
            }
          end
        rescue A3::Domain::ConfigurationError, JSON::ParserError
          retained << File.basename(path, ".json")
        end

        enforce_count_retention!(retained_records, max_count_by_class, deleted, retained, dry_run)
        enforce_byte_retention!(retained_records, max_bytes_by_class, deleted, retained, dry_run)

        CleanupResult.new(deleted_artifact_ids: deleted, retained_artifact_ids: retained, missing_blob_artifact_ids: missing_blob, dry_run: dry_run)
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

      def metadata_paths
        Dir.glob(File.join(storage_dir, "*.json")).sort
      end

      def artifact_id_from_metadata_path(path)
        File.basename(path, ".json")
      end

      def expired?(metadata, blob, now:, ttl:)
        mtime = newest_mtime(metadata, blob)
        return false unless mtime

        mtime <= now - ttl
      end

      def newest_mtime(metadata, blob)
        [metadata, blob].select { |path| File.exist?(path) }.map { |path| File.mtime(path) }.max
      end

      def enforce_count_retention!(records, max_count_by_class, deleted, retained, dry_run)
        max_count_by_class.each do |retention_class, max_count|
          next unless max_count

          class_records = sorted_retained_records(records, retention_class)
          keep_count = [max_count.to_i, 0].max
          delete_count = [class_records.size - keep_count, 0].max
          class_records.first(delete_count).each do |record|
            delete_retained_record!(record, records, deleted, retained, dry_run)
          end
        end
      end

      def enforce_byte_retention!(records, max_bytes_by_class, deleted, retained, dry_run)
        max_bytes_by_class.each do |retention_class, max_bytes|
          next unless max_bytes

          class_records = sorted_retained_records(records, retention_class)
          total_bytes = class_records.sum { |record| record.fetch(:byte_size).to_i }
          class_records.each do |record|
            break if total_bytes <= max_bytes.to_i

            total_bytes -= record.fetch(:byte_size).to_i
            delete_retained_record!(record, records, deleted, retained, dry_run)
          end
        end
      end

      def sorted_retained_records(records, retention_class)
        records
          .select { |record| record.fetch(:retention_class) == retention_class.to_sym }
          .sort_by { |record| [record.fetch(:mtime) || Time.at(0), record.fetch(:artifact_id)] }
      end

      def delete_retained_record!(record, records, deleted, retained, dry_run)
        artifact_id = record.fetch(:artifact_id)
        return if deleted.include?(artifact_id)

        deleted << artifact_id
        retained.delete(artifact_id)
        records.delete(record)
        delete_artifact_files(record.fetch(:metadata), record.fetch(:blob)) unless dry_run
      end

      def delete_artifact_files(metadata, blob)
        FileUtils.rm_f(blob)
        FileUtils.rm_f(metadata)
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
