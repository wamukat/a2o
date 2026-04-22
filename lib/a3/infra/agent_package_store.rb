# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "rubygems/package"
require "zlib"

module A3
  module Infra
    class AgentPackageStore
      DEFAULT_PACKAGE_DIR = "/opt/a2o/agents"
      CONTRACT_PATH = "package-compatibility.json"

      Package = Struct.new(:target, :version, :goos, :goarch, :archive, :sha256, keyword_init: true) do
        def archive_path(package_dir)
          File.join(package_dir, archive)
        end
      end

      Contract = Struct.new(:schema, :package_version, :runtime_version, :archive_manifest, :launcher_layout, keyword_init: true)

      def initialize(package_dir: ENV.fetch("A2O_AGENT_PACKAGE_DIR", ENV.fetch("A3_AGENT_PACKAGE_DIR", DEFAULT_PACKAGE_DIR)))
        @package_dir = File.expand_path(package_dir)
      end

      attr_reader :package_dir

      def list
        manifest_packages
      end

      def contract
        path = File.join(package_dir, CONTRACT_PATH)
        return nil unless File.file?(path)

        payload = JSON.parse(File.read(path))
        Contract.new(
          schema: payload.fetch("schema"),
          package_version: payload.fetch("package_version"),
          runtime_version: payload.fetch("runtime_version"),
          archive_manifest: payload.fetch("archive_manifest"),
          launcher_layout: payload.fetch("launcher_layout")
        )
      rescue JSON::ParserError, KeyError => e
        raise A3::Domain::ConfigurationError, "invalid agent package compatibility contract: #{path} (#{e.message})"
      end

      def verify(target: nil)
        validate_runtime_compatibility!(expected_runtime_version: A3::VERSION)
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
        validate_runtime_compatibility!(expected_runtime_version: A3::VERSION)
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
          sha256: package.sha256,
          package_version: package.version,
          runtime_version: contract&.runtime_version || inferred_runtime_version
        }
      end

      def validate_runtime_compatibility!(expected_runtime_version:)
        expected = expected_runtime_version.to_s.strip
        return if expected.empty?

        actual =
          if (contract_payload = contract)
            unless contract_payload.schema == "a2o-agent-package-compatibility/v1"
              raise A3::Domain::ConfigurationError, "unsupported agent package compatibility schema: #{contract_payload.schema}"
            end
            unless manifest_present?
              raise A3::Domain::ConfigurationError,
                    "agent package manifest not found for compatibility contract: #{manifest_path}"
            end
            manifest_version = manifest_present? ? inferred_runtime_version : ""
            if !manifest_version.empty? && contract_payload.package_version.to_s.strip != manifest_version
              raise A3::Domain::ConfigurationError,
                    "agent package contract mismatch: contract_package_version=#{contract_payload.package_version} manifest_package_version=#{manifest_version}"
            end
            contract_payload.runtime_version.to_s.strip
          else
            inferred_runtime_version
          end

        return if actual == expected

        raise A3::Domain::ConfigurationError,
              "agent package runtime compatibility mismatch: package_runtime_version=#{actual} expected_runtime_version=#{expected}"
      end

      private

      def manifest_path
        File.join(package_dir, contract&.archive_manifest || "release-manifest.jsonl")
      end

      def manifest_present?
        File.file?(manifest_path)
      end

      def inferred_runtime_version
        versions = list.map(&:version).map(&:to_s).reject(&:empty?).uniq
        return "" if versions.empty?
        return versions.first if versions.one?

        raise A3::Domain::ConfigurationError, "agent package manifest mixes multiple package versions: #{versions.join(',')}"
      end

      def manifest_packages
        path = manifest_path
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
