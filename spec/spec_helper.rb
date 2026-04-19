# frozen_string_literal: true

require "a3"
require "yaml"
Dir[File.join(__dir__, "support", "**", "*.rb")].sort.each { |path| require path }

module RepoSourceFixtureHelper
  def create_repo_sources(base_dir, slots: %i[repo_alpha repo_beta])
    sources_dir = File.join(base_dir, "repo-sources")
    FileUtils.mkdir_p(sources_dir)

    slots.each_with_object({}) do |slot, repo_sources|
      slot_dir = File.join(sources_dir, slot.to_s.gsub("_", "-"))
      FileUtils.mkdir_p(slot_dir)
      File.write(File.join(slot_dir, "README.md"), "#{slot} source\n")
      repo_sources[slot] = slot_dir
    end
  end

  def repo_source_args(repo_sources)
    repo_sources.flat_map do |slot, path|
      ["--repo-source", "#{slot}=#{path}"]
    end
  end

  def create_git_repo_source(base_dir, name:, file_name: "README.md", file_content: "git source\n")
    repo_dir = File.join(base_dir, name)
    FileUtils.mkdir_p(repo_dir)
    Dir.chdir(repo_dir) do
      system("git", "init", "-q")
      system("git", "config", "user.name", "A3 Test")
      system("git", "config", "user.email", "a3-test@example.com")
      File.write(file_name, file_content)
      system("git", "add", file_name)
      system("git", "commit", "-q", "-m", "initial commit")
      `git rev-parse HEAD`.strip
    end
  end
end

module EnvFixtureHelper
  def with_env(overrides)
    originals = overrides.each_with_object({}) do |(key, _value), memo|
      memo[key] = ENV.key?(key) ? ENV[key] : :__missing__
    end

    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    originals.each do |key, value|
      value == :__missing__ ? ENV.delete(key) : ENV[key] = value
    end
  end
end

module ProjectYamlFixtureHelper
  def project_yaml_payload(merge_target: "merge_to_live", merge_policy: "ff_only", merge_target_ref: "refs/heads/main")
    {
      "schema_version" => 1,
      "runtime" => {
        "phases" => {
          "implementation" => {
            "skill" => "skills/implementation/base.md"
          },
          "review" => {
            "skill" => "skills/review/default.md"
          },
          "parent_review" => {
            "skill" => "skills/review/parent.md"
          },
          "verification" => {
            "commands" => ["commands/verify-all"]
          },
          "remediation" => {
            "commands" => ["commands/apply-remediation"]
          },
          "merge" => {
            "target" => merge_target,
            "policy" => merge_policy,
            "target_ref" => merge_target_ref
          }
        }
      }
    }
  end

  def write_project_yaml(path, **kwargs)
    File.write(path, YAML.dump(project_yaml_payload(**kwargs)))
  end
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.include RepoSourceFixtureHelper
  config.include ParentChildTaskFixtureHelper
  config.include FakeKanbanCliHelper
  config.include EnvFixtureHelper
  config.include ProjectYamlFixtureHelper
  config.around do |example|
    original = ENV.key?("A3_SECRET_REFERENCE") ? ENV["A3_SECRET_REFERENCE"] : :__missing__
    ENV["A3_SECRET_REFERENCE"] = "A3_SECRET"
    example.run
  ensure
    original == :__missing__ ? ENV.delete("A3_SECRET_REFERENCE") : ENV["A3_SECRET_REFERENCE"] = original
  end
end
