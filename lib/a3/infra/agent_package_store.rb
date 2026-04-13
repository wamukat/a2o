# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "rubygems/package"
require "zlib"

module A3
  module Infra
    class AgentPackageStore
      DEFAULT_PACKAGE_DIR = "/opt/a3/agents"

      Package = Struct.new(:target, :version, :goos, :goarch, :archive, :sha256, keyword_init: true) do
        def archive_path(package_dir)
          File.join(package_dir, archive)
        end
      end

      def initialize(package_dir: ENV.fetch("A3_AGENT_PACKAGE_DIR", DEFAULT_PACKAGE_DIR))
        @package_dir = File.expand_path(package_dir)
      end

      attr_reader :package_dir

      def list
        manifest_packages
      end

      def verify(target: nil)
        selected_packages(target: target).map do |package|
          actual = Digest::SHA256.file(package.archive_path(package_dir)).hexdigest
          {
            target: package.target,
            archive: package.archive,
            expected_sha256: package.sha256,
            actual_sha256: actual,
            ok: actual == package.sha256
          }
        end
      end

      def export(target:, output:)
        package = package_for(target)
        verification = verify(target: target).fetch(0)
        raise A3::Domain::ConfigurationError, "agent package checksum mismatch for #{target}" unless verification.fetch(:ok)

        FileUtils.mkdir_p(File.dirname(File.expand_path(output)))
        extract_agent_binary(package.archive_path(package_dir), output)
        FileUtils.chmod(0o755, output)
        {
          target: package.target,
          output: File.expand_path(output),
          archive: package.archive,
          sha256: package.sha256
        }
      end

      private

      def manifest_packages
        path = File.join(package_dir, "release-manifest.jsonl")
        raise A3::Domain::ConfigurationError, "agent package manifest not found: #{path}" unless File.file?(path)

        File.readlines(path, chomp: true).reject(&:empty?).map do |line|
          payload = JSON.parse(line)
          goos = payload.fetch("goos")
          goarch = payload.fetch("goarch")
          archive = payload.fetch("archive")
          sha256 = payload.fetch("sha256")
          Package.new(
            target: "#{goos}-#{goarch}",
            version: payload.fetch("version", ""),
            goos: goos,
            goarch: goarch,
            archive: archive,
            sha256: sha256
          )
        end.sort_by(&:target)
      rescue JSON::ParserError => e
        raise A3::Domain::ConfigurationError, "invalid agent package manifest: #{path} (#{e.message})"
      end

      def selected_packages(target:)
        packages = list
        return packages unless target

        [package_for(target)]
      end

      def package_for(target)
        normalized = target.to_s.tr("/", "-")
        package = list.find { |item| item.target == normalized }
        raise A3::Domain::ConfigurationError, "agent package target not found: #{target}" unless package
        raise A3::Domain::ConfigurationError, "agent package archive not found: #{package.archive_path(package_dir)}" unless File.file?(package.archive_path(package_dir))

        package
      end

      def extract_agent_binary(archive_path, output)
        found = false
        Zlib::GzipReader.open(archive_path) do |gzip|
          Gem::Package::TarReader.new(gzip) do |tar|
            tar.each do |entry|
              next unless entry.file?
              next unless File.basename(entry.full_name) == "a3-agent"

              File.open(output, "wb") { |file| file.write(entry.read) }
              found = true
              break
            end
          end
        end
        raise A3::Domain::ConfigurationError, "agent package archive does not contain a3-agent: #{archive_path}" unless found
      end
    end
  end
end
