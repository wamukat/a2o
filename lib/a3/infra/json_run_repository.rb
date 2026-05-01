# frozen_string_literal: true

require "json"
require "fileutils"
require "tempfile"

module A3
  module Infra
    class JsonRunRepository
      include A3::Domain::RunRepository
      RECORD_CORRUPTION_ERRORS = [KeyError, TypeError, ArgumentError, NoMethodError].freeze

      def initialize(path)
        @path = path
      end

      def save(run)
        with_records_lock do
          records = load_records_for_write
          records[run.ref] = A3::Adapters::RunRecord.dump(run)
          write_records(records)
        end
      end

      def fetch(run_ref)
        record = with_records_lock { load_records.fetch(run_ref) }
        A3::Adapters::RunRecord.load(record)
      rescue *RECORD_CORRUPTION_ERRORS
        raise A3::Domain::RecordNotFound, "Run not found: #{run_ref}"
      end

      def all
        with_records_lock do
          load_records
            .values
            .filter_map { |record| load_valid_record(record) }
            .freeze
        end
      end

      def corrupt_run_refs
        with_records_lock do
          load_records
            .each_with_object([]) do |(ref, record), refs|
              refs << ref unless load_valid_record(record)
            end
            .freeze
        end
      end

      private

      def with_records_lock
        FileUtils.mkdir_p(File.dirname(@path))
        File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def lock_path
        "#{@path}.lock"
      end

      def load_records
        return {} unless File.exist?(@path)

        records = JSON.parse(File.read(@path))
        records.is_a?(Hash) ? records : {}
      rescue JSON::ParserError
        {}
      end

      def load_records_for_write
        return {} unless File.exist?(@path)

        records = JSON.parse(File.read(@path))
        return records if records.is_a?(Hash)

        quarantine_corrupt_store
        {}
      rescue JSON::ParserError
        quarantine_corrupt_store
        {}
      end

      def write_records(records)
        FileUtils.mkdir_p(File.dirname(@path))
        temp_path = nil
        Tempfile.create([File.basename(@path), ".tmp"], File.dirname(@path)) do |file|
          temp_path = file.path
          file.write(JSON.pretty_generate(records))
          file.flush
          file.fsync
          file.close
          File.rename(temp_path, @path)
          temp_path = nil
        end
      ensure
        FileUtils.rm_f(temp_path) if temp_path && File.exist?(temp_path)
      end

      def load_valid_record(record)
        A3::Adapters::RunRecord.load(record)
      rescue *RECORD_CORRUPTION_ERRORS
        nil
      end

      def quarantine_corrupt_store
        return unless File.exist?(@path)

        FileUtils.mv(@path, corrupt_store_path)
      end

      def corrupt_store_path
        "#{@path}.corrupt.#{Time.now.utc.strftime('%Y%m%d%H%M%S')}.#{$$}.#{Thread.current.object_id}"
      end
    end
  end
end
