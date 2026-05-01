# frozen_string_literal: true

RSpec.describe A3::Domain::SourceRemote do
  describe ".external_reference_payload" do
    it "normalizes Kanbalone remote metadata into an external reference payload" do
      payload = described_class.external_reference_payload(
        "provider" => "github",
        "display_ref" => "wamukat/a2o#41",
        "url" => "https://github.com/wamukat/a2o/issues/41",
        "remote_title" => "Runtime stalls"
      )

      expect(payload).to eq(
        "provider" => "github",
        "instanceUrl" => "https://github.com",
        "resourceType" => "issue",
        "projectKey" => "wamukat/a2o",
        "issueKey" => "41",
        "displayRef" => "wamukat/a2o#41",
        "url" => "https://github.com/wamukat/a2o/issues/41",
        "title" => "Runtime stalls"
      )
    end

    it "returns nil when required external reference fields cannot be derived" do
      expect(described_class.external_reference_payload("provider" => "github")).to be_nil
    end
  end
end
