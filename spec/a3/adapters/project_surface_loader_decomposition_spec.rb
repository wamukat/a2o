# frozen_string_literal: true

require "tmpdir"
require "yaml"

RSpec.describe A3::Adapters::ProjectSurfaceLoader do
  def write_project_yaml(dir, runtime)
    path = File.join(dir, "project.yaml")
    File.write(path, YAML.dump("schema_version" => 1, "runtime" => runtime))
    path
  end

  def base_phases
    {
      "implementation" => { "skill" => "skills/implementation.md" },
      "review" => { "skill" => "skills/review.md" }
    }
  end

  it "loads decomposition investigate command from project.yaml" do
    Dir.mktmpdir do |dir|
      path = write_project_yaml(
        dir,
        {
          "phases" => base_phases,
          "decomposition" => {
            "investigate" => {
              "command" => ["commands/investigate.sh", "--format", "json"]
            }
          }
        }
      )

      surface = described_class.new(preset_dir: File.join(dir, "presets")).load(path)

      expect(surface.decomposition_investigate_command).to eq(["commands/investigate.sh", "--format", "json"])
    end
  end

  it "rejects invalid decomposition investigate command declarations" do
    Dir.mktmpdir do |dir|
      path = write_project_yaml(
        dir,
        {
          "phases" => base_phases,
          "decomposition" => {
            "investigate" => {
              "command" => "commands/investigate.sh"
            }
          }
        }
      )

      expect do
        described_class.new(preset_dir: File.join(dir, "presets")).load(path)
      end.to raise_error(
        A3::Domain::ConfigurationError,
        /runtime.decomposition.investigate.command must be a non-empty array/
      )
    end
  end
end
