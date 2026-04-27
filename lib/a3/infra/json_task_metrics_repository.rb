# frozen_string_literal: true

require "json"
require "fileutils"
require "tempfile"

module A3
  module Infra
    class JsonTaskMetricsRepository
      include A3::Domain::TaskMetricsRepository
      RECORD_CORRUPTION_ERRORS = [KeyError, TypeError, ArgumentError, NoMethodError].freeze

      def initialize(path)
        @path = path
      end

      def save(record)
        records = load_records_for_write
        records << A3::Adapters::TaskMetricsRecord.dump(record)
        write_records(records)
      end

      def all
        load_records.filter_map do |record|
          A3::Adapters::TaskMetricsRecord.load(record)
        rescue *RECORD_CORRUPTION_ERRORS
          nil
        end.freeze
      end

      private

      def load_records
        return [] unless File.exist?(@path)

        records = JSON.parse(File.read(@path))
        records.is_a?(Array) ? records : []
      rescue JSON::ParserError
        []
      end

      def load_records_for_write
        return [] unless File.exist?(@path)

        records = JSON.parse(File.read(@path))
        return records if records.is_a?(Array)

        quarantine_corrupt_store
        []
      rescue JSON::ParserError
        quarantine_corrupt_store
        []
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

      def quarantine_corrupt_store
        return unless File.exist?(@path)

        FileUtils.mv(@path, "#{@path}.corrupt.#{Time.now.utc.strftime('%Y%m%d%H%M%S')}.#{$$}.#{Thread.current.object_id}")
      end
    end
  end
end
