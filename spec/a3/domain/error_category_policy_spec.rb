# frozen_string_literal: true

require "json"
require "spec_helper"

RSpec.describe A3::Domain::ErrorCategoryPolicy do
  let(:fixture_path) { File.expand_path("../../../testdata/error_category_cases.json", __dir__) }
  let(:fixture_data) { JSON.parse(File.read(fixture_path)) }

  describe ".worker_error_category" do
    it "matches the shared worker contract cases" do
      fixture_data.fetch("worker_cases").each do |fixture|
        actual = described_class.worker_error_category(
          summary: fixture.fetch("summary"),
          observed_state: fixture.fetch("observed_state"),
          phase: fixture.fetch("phase")
        )
        expect(actual).to eq(fixture.fetch("category")), fixture.fetch("name")
      end
    end
  end

  describe ".blocked_error_category" do
    it "matches the shared blocked contract cases" do
      fixture_data.fetch("blocked_cases").each do |fixture|
        actual = described_class.blocked_error_category(
          phase: fixture.fetch("phase"),
          diagnostic_summary: fixture.fetch("diagnostic_summary"),
          observed_state: fixture.fetch("observed_state"),
          failing_command: fixture.fetch("failing_command"),
          infra_diagnostics: fixture.fetch("infra_diagnostics")
        )
        expect(actual).to eq(fixture.fetch("category")), fixture.fetch("name")
      end
    end
  end
end
