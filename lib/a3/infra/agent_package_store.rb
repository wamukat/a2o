# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open-uri"
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
      Publication = Struct.new(:schema, :version, :bundle_archive, :bundle_url, :bundle_archive_sha256, :compatibility_contract, :archive_manifest, :checksums_file, :package_source_hint, keyword_init: true)

      def initialize(package_dir: ENV.fetch("A2O_AGENT_PACKAGE_DIR", ENV.fetch("A3_AGENT_PACKAGE_DIR", DEFAULT_PACKAGE_DIR)))
        @package_dir = File.expand_path(package_dir)
      end

      attr_reader :package_dir

      def list
        return external_store.list if publication && !complete_host_launcher_set?

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

      def publication
        path = File.join(package_dir, "package-publication.json")
        return nil unless File.file?(path)

        payload = JSON.parse(File.read(path))
        Publication.new(
          schema: payload.fetch("schema"),
          version: payload.fetch("version"),
          bundle_archive: payload.fetch("bundle_archive"),
          bundle_url: payload.fetch("bundle_url"),
          bundle_archive_sha256: payload.fetch("bundle_archive_sha256"),
          compatibility_contract: payload.fetch("compatibility_contract"),
          archive_manifest: payload.fetch("archive_manifest"),
          checksums_file: payload.fetch("checksums_file"),
          package_source_hint: payload.fetch("package_source_hint")
        )
      rescue JSON::ParserError, KeyError => e
        raise A3::Domain::ConfigurationError, "invalid agent package publication descriptor: #{path} (#{e.message})"
      end

      def verify(target: nil)
        return external_store.verify(target: target) if publication && !manifest_present?

        validate_runtime_compatibility!(expected_runtime_version: A3::VERSION)
        selected_packages(target: target).map do |package|
          actual = Digest::SHA256.file(resolved_archive_path(package)).hexdigest
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
        extract_agent_binary(resolved_archive_path(package), output)
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

      def resolved_host_install_package_dir
        return package_dir unless publication
        return package_dir if complete_host_launcher_set?

        external_store.package_dir
      end

      def validate_runtime_compatibility!(expected_runtime_version:, require_complete_host_launcher_set: false)
        expected = expected_runtime_version.to_s.strip
        return if expected.empty?
        return external_store.validate_runtime_compatibility!(expected_runtime_version: expected) if publication && !manifest_present?

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

        unless actual == expected
          raise A3::Domain::ConfigurationError,
                "agent package runtime compatibility mismatch: package_runtime_version=#{actual} expected_runtime_version=#{expected}"
        end

        if require_complete_host_launcher_set && publication && !complete_host_launcher_set?
          external_store.validate_runtime_compatibility!(expected_runtime_version: expected)
        end
      end

      private

      def manifest_path
        File.join(package_dir, contract&.archive_manifest || "release-manifest.jsonl")
      end

      def manifest_present?
        File.file?(manifest_path)
      end

      def inferred_runtime_version
        packages = manifest_present? ? manifest_packages : list
        versions = packages.map(&:version).map(&:to_s).reject(&:empty?).uniq
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
        return [package_for(target)] if target

        list
      end

      def package_for(target)
        return external_store.send(:package_for, target) if publication && !manifest_present?

        normalized = target.to_s.tr("/", "-")
        local_package = manifest_packages.find { |item| item.target == normalized } if manifest_present?
        if local_package && File.file?(local_package.archive_path(package_dir))
          return local_package
        end

        package = list.find { |item| item.target == normalized }
        if package.nil? && publication
          return external_store.send(:package_for, target)
        end
        raise A3::Domain::ConfigurationError, "agent package target not found: #{target}" unless package
        unless File.file?(package.archive_path(package_dir))
          return external_store.send(:package_for, target) if publication

          raise A3::Domain::ConfigurationError, "agent package archive not found: #{package.archive_path(package_dir)}"
        end

        package
      end

      def external_store
        publication_payload = publication
        raise A3::Domain::ConfigurationError, "agent package publication descriptor not found" unless publication_payload

        @external_store ||= self.class.new(package_dir: materialize_publication_bundle(publication_payload))
      end

      def materialize_publication_bundle(publication_payload)
        unless publication_payload.schema == "a2o-agent-package-publication/v1"
          raise A3::Domain::ConfigurationError, "unsupported agent package publication schema: #{publication_payload.schema}"
        end

        cache_root = ENV.fetch("A2O_AGENT_PACKAGE_CACHE_DIR", ENV.fetch("A3_AGENT_PACKAGE_CACHE_DIR", "/tmp/a2o-agent-package-cache"))
        cache_key = "#{publication_payload.version}-#{publication_payload.bundle_archive_sha256}"
        cache_dir = File.join(File.expand_path(cache_root), cache_key)
        extracted_dir = File.join(cache_dir, "bundle")
        ready_marker = File.join(extracted_dir, ".ready")
        return extracted_dir if File.file?(ready_marker)

        FileUtils.rm_rf(cache_dir)
        FileUtils.mkdir_p(extracted_dir)
        bundle_path = File.join(cache_dir, publication_payload.bundle_archive)
        if publication_payload.bundle_url.start_with?("file://")
          FileUtils.cp(URI(publication_payload.bundle_url).path, bundle_path)
        else
          URI.open(publication_payload.bundle_url, "rb") do |input|
            File.open(bundle_path, "wb") { |output| IO.copy_stream(input, output) }
          end
        end
        actual_sha256 = Digest::SHA256.file(bundle_path).hexdigest
        if actual_sha256 != publication_payload.bundle_archive_sha256
          raise A3::Domain::ConfigurationError, "agent package bundle checksum mismatch: #{publication_payload.bundle_archive}"
        end
        extract_bundle(bundle_path, extracted_dir)
        File.write(ready_marker, "ready\n")
        extracted_dir
      rescue OpenURI::HTTPError, SocketError => e
        raise A3::Domain::ConfigurationError, "failed to fetch agent package bundle: #{e.message}"
      end

      def extract_bundle(bundle_path, destination)
        Zlib::GzipReader.open(bundle_path) do |gzip|
          Gem::Package::TarReader.new(gzip) do |tar|
            tar.each do |entry|
              target_path = File.join(destination, entry.full_name)
              if entry.directory?
                FileUtils.mkdir_p(target_path)
                next
              end

              FileUtils.mkdir_p(File.dirname(target_path))
              File.open(target_path, "wb") { |file| file.write(entry.read) }
              FileUtils.chmod(entry.header.mode, target_path) if entry.header.mode
            end
          end
        end
      end

      def complete_host_launcher_set?
        return false unless manifest_present?

        required_targets = %w[darwin-amd64 darwin-arm64 linux-amd64 linux-arm64]
        available_targets = manifest_packages.map(&:target)
        required_targets.all? do |target|
          available_targets.include?(target) && File.file?(File.join(package_dir, target, "a3"))
        end
      rescue A3::Domain::ConfigurationError
        false
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

      def resolved_archive_path(package)
        local_path = package.archive_path(package_dir)
        return local_path if File.file?(local_path)

        return package.archive_path(external_store.package_dir) if publication

        local_path
      end
    end
  end
end
