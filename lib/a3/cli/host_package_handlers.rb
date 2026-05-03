# frozen_string_literal: true

require "fileutils"
require "optparse"

module A3
  module CLI
    module HostPackageHandlers
    def handle_agent(argv, out:)
      subject = argv.shift
      action = argv.shift
      unless subject == "package" && %w[list export verify].include?(action)
        raise ArgumentError, "usage: a2o agent package list|export|verify"
      end

      options = parse_agent_package_options(argv)
      store = A3::Infra::AgentPackageStore.new(package_dir: options.fetch(:package_dir))

      case action
      when "list"
        packages = store.list
        out.puts("agent_package_dir=#{store.package_dir}")
        if (contract = store.contract)
          out.puts("agent_package_contract schema=#{contract.schema} package_version=#{contract.package_version} runtime_version=#{contract.runtime_version} archive_manifest=#{contract.archive_manifest} launcher_layout=#{contract.launcher_layout}")
        else
          out.puts("agent_package_contract schema=legacy-runtime-manifest runtime_version=#{store.send(:inferred_runtime_version)}")
        end
        packages.each do |package|
          out.puts("target=#{package.target} version=#{package.version} archive=#{package.archive} sha256=#{package.sha256}")
        end
      when "verify"
        results = store.verify(target: options[:target])
        results.each do |result|
          out.puts("target=#{result.fetch(:target)} archive=#{result.fetch(:archive)} ok=#{result.fetch(:ok)} sha256=#{result.fetch(:actual_sha256)}")
        end
        raise A3::Domain::ConfigurationError, "agent package verification failed" unless results.all? { |result| result.fetch(:ok) }
      when "export"
        target = options.fetch(:target) { raise ArgumentError, "--target is required for agent package export" }
        output = options.fetch(:output) { raise ArgumentError, "--output is required for agent package export" }
        result = store.export(target: target, output: output)
        out.puts("agent_package_exported target=#{result.fetch(:target)} output=#{result.fetch(:output)} archive=#{result.fetch(:archive)} sha256=#{result.fetch(:sha256)}")
      end
    end

    def handle_host(argv, out:)
      action = argv.shift
      unless action == "install"
        raise ArgumentError, "usage: a2o host install --output-dir DIR"
      end

      options = parse_host_install_options(argv)
      package_dir = options.fetch(:package_dir)
      output_dir = options.fetch(:output_dir)
      share_dir = options.fetch(:share_dir)
      FileUtils.mkdir_p(output_dir)

      installed_targets = install_host_launchers(package_dir: package_dir, output_dir: output_dir)
      installed_share_dir = install_host_share_assets(share_dir: share_dir)
      install_runtime_image_reference(share_dir: share_dir, runtime_image: options[:runtime_image])
      wrapper_path = File.join(output_dir, "a2o")
      File.write(wrapper_path, host_launcher_wrapper)
      FileUtils.chmod(0o755, wrapper_path)
      remove_legacy_host_launchers(output_dir: output_dir)

      out.puts("host_launcher_installed output=#{wrapper_path} targets=#{installed_targets.join(',')}")
      out.puts("host_share_installed output=#{installed_share_dir}") if installed_share_dir
      out.puts("host_runtime_image=#{options[:runtime_image]}") if options[:runtime_image]
    end


    def parse_agent_package_options(argv)
      options = {
        package_dir: A3::Infra::AgentPackageStore.default_package_dir
      }
      parser = OptionParser.new
      parser.on("--package-dir DIR") { |value| options[:package_dir] = File.expand_path(value) }
      parser.on("--target TARGET") { |value| options[:target] = value.to_s.tr("/", "-") }
      parser.on("--output PATH") { |value| options[:output] = File.expand_path(value) }
      parser.parse!(argv)
      options
    end

    def parse_host_install_options(argv)
      options = {
        package_dir: A3::Infra::AgentPackageStore.default_package_dir
      }
      parser = OptionParser.new
      parser.on("--package-dir DIR") { |value| options[:package_dir] = File.expand_path(value) }
      parser.on("--output-dir DIR") { |value| options[:output_dir] = File.expand_path(value) }
      parser.on("--share-dir DIR") { |value| options[:share_dir] = File.expand_path(value) }
      parser.on("--runtime-image IMAGE") { |value| options[:runtime_image] = value.to_s.strip }
      parser.parse!(argv)
      options.fetch(:output_dir) { raise ArgumentError, "--output-dir is required for host install" }
      options[:share_dir] ||= File.expand_path(File.join(options.fetch(:output_dir), "..", "share", "a2o"))
      options
    end

    def install_host_launchers(package_dir:, output_dir:)
      package_store = validate_host_package_dir!(package_dir)
      resolved_dir = package_store&.resolved_host_install_package_dir || package_dir
      targets = Dir.glob(File.join(resolved_dir, "*", "a2o")).sort.map do |source|
        target = File.basename(File.dirname(source))
        destination = File.join(output_dir, "a2o-#{target}")
        FileUtils.cp(source, destination)
        FileUtils.chmod(0o755, destination)
        target
      end
      raise A3::Domain::ConfigurationError, "host launcher binaries not found under #{package_dir}" if targets.empty?

      targets
    end

    def remove_legacy_host_launchers(output_dir:)
      Dir.glob(File.join(output_dir, "a3-*")).each { |path| FileUtils.rm_f(path) }
      FileUtils.rm_f(File.join(output_dir, "a3"))
    end

    def validate_host_package_dir!(package_dir)
      manifest_path = File.join(package_dir, "release-manifest.jsonl")
      contract_path = File.join(package_dir, A3::Infra::AgentPackageStore::CONTRACT_PATH)
      publication_path = File.join(package_dir, "package-publication.json")
      return nil unless File.file?(manifest_path) || File.file?(contract_path) || File.file?(publication_path)

      store = A3::Infra::AgentPackageStore.new(package_dir: package_dir)
      store.validate_runtime_compatibility!(expected_runtime_version: A3::VERSION, require_complete_host_launcher_set: true)
      resolved_dir = store.resolved_host_install_package_dir
      if resolved_dir != package_dir
        A3::Infra::AgentPackageStore.new(package_dir: resolved_dir).validate_runtime_compatibility!(expected_runtime_version: A3::VERSION)
      end
      store
    end

    def install_host_share_assets(share_dir:)
      if ENV.key?("A3_SHARE_DIR") && ENV.fetch("A2O_SHARE_DIR", "").to_s.strip.empty?
        raise A3::Domain::ConfigurationError,
              "removed A3 compatibility input: environment variable A3_SHARE_DIR; migration_required=true replacement=environment variable A2O_SHARE_DIR"
      end
      source_dir = ENV.fetch("A2O_SHARE_DIR", "/opt/a2o/share")
      return nil unless Dir.exist?(source_dir)

      FileUtils.mkdir_p(File.dirname(share_dir))
      FileUtils.rm_rf(share_dir)
      FileUtils.cp_r(source_dir, share_dir)
      share_dir
    end

    def install_runtime_image_reference(share_dir:, runtime_image:)
      return if runtime_image.nil? || runtime_image.empty?

      FileUtils.mkdir_p(share_dir)
      File.write(File.join(share_dir, "runtime-image"), "#{runtime_image}\n")
    end

    def host_launcher_wrapper
      <<~'SH'
        #!/usr/bin/env sh
        set -eu

        os="$(uname -s)"
        arch="$(uname -m)"
        case "$os" in
          Darwin) os_part="darwin" ;;
          Linux) os_part="linux" ;;
          *) echo "unsupported host OS: $os" >&2; exit 2 ;;
        esac
        case "$arch" in
          x86_64|amd64) arch_part="amd64" ;;
          arm64|aarch64) arch_part="arm64" ;;
          *) echo "unsupported host architecture: $arch" >&2; exit 2 ;;
        esac

        dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
        command_name="$(basename "$0")"
        case "$command_name" in
          a2o) binary="$dir/a2o-$os_part-$arch_part" ;;
          *)
            echo "removed A3 host launcher alias: $command_name; migration_required=true replacement=a2o" >&2
            exit 2
            ;;
        esac
        if [ ! -x "$binary" ]; then
          echo "A2O host launcher not found for ${os_part}-${arch_part}: $binary" >&2
          exit 1
        fi
        exec "$binary" "$@"
      SH
    end


    end
  end
end
