# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"

RSpec.describe "reference product commands" do
  it "uses worker slot_paths when multi-repo verification is not run from the workspace root" do
    Dir.mktmpdir do |dir|
      repo_alpha = File.join(dir, "repo_alpha")
      repo_beta = File.join(dir, "repo_beta")
      command_dir = File.join(dir, "command-cwd")
      bin_dir = File.join(dir, "bin")
      log_path = File.join(dir, "npm.log")
      request_path = File.join(dir, "request.json")

      [repo_alpha, repo_beta, command_dir, bin_dir].each { |path| FileUtils.mkdir_p(path) }
      File.write(
        File.join(bin_dir, "npm"),
        "#!/usr/bin/env sh\nset -eu\npwd >> \"$NPM_LOG\"\n"
      )
      FileUtils.chmod("+x", File.join(bin_dir, "npm"))
      File.write(
        request_path,
        JSON.generate("slot_paths" => { "repo_alpha" => repo_alpha, "repo_beta" => repo_beta })
      )

      script = File.expand_path("../../reference-products/multi-repo-fixture/project-package/commands/verify-all.sh", __dir__)
      env = {
        "A2O_WORKER_REQUEST_PATH" => request_path,
        "NPM_LOG" => log_path,
        "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}"
      }
      _stdout, stderr, status = Open3.capture3(env, script, chdir: command_dir)

      expect(status).to be_success, stderr
      expect(File.readlines(log_path, chomp: true)).to eq([repo_alpha, repo_beta])
    end
  end

  it "uses the app slot_path for Java Spring multi-module verification" do
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app")
      command_dir = File.join(dir, "command-cwd")
      bin_dir = File.join(dir, "bin")
      log_path = File.join(dir, "mvn.log")
      request_path = File.join(dir, "request.json")
      product_root = File.join(app, "reference-products/java-spring-multi-module")

      [product_root, command_dir, bin_dir].each { |path| FileUtils.mkdir_p(path) }
      File.write(
        File.join(bin_dir, "mvn"),
        "#!/usr/bin/env sh\nset -eu\npwd >> \"$MVN_LOG\"\n"
      )
      FileUtils.chmod("+x", File.join(bin_dir, "mvn"))
      File.write(request_path, JSON.generate("slot_paths" => { "app" => app }))

      script = File.expand_path("../../reference-products/java-spring-multi-module/project-package/commands/verify.sh", __dir__)
      env = {
        "A2O_WORKER_REQUEST_PATH" => request_path,
        "MVN_LOG" => log_path,
        "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}"
      }
      _stdout, stderr, status = Open3.capture3(env, script, chdir: command_dir)

      expect(status).to be_success, stderr
      expect(File.readlines(log_path, chomp: true)).to eq([product_root])
    end
  end
end
