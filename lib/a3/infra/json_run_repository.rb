# frozen_string_literal: true

require "json"
require "fileutils"

module A3
  module Infra
    class JsonRunRepository
      include A3::Domain::RunRepository

      def initialize(path)
        @path = path
      end

      def save(run)
        records = load_records
        records[run.ref] = A3::Adapters::RunRecord.dump(run)
        write_records(records)
      end

      def fetch(run_ref)
        record = load_records.fetch(run_ref)
        A3::Adapters::RunRecord.load(record)
      rescue KeyError
        raise A3::Domain::RecordNotFound, "Run not found: #{run_ref}"
      end

      def all
        load_records
          .values
          .map { |record| A3::Adapters::RunRecord.load(record) }
          .freeze
      end

      private

      def load_records
        return {} unless File.exist?(@path)

        JSON.parse(File.read(@path))
      end

      def write_records(records)
        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, JSON.pretty_generate(records))
      end
    end
  end
end
