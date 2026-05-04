# frozen_string_literal: true

require "spec_helper"

RSpec.describe A3::Domain::ReviewDisposition do
  it "accepts clean completed review evidence without a finding key" do
    disposition = described_class.from_response_bundle(
      "review_disposition" => {
        "kind" => "completed",
        "slot_scopes" => ["repo_alpha"],
        "summary" => "self-review clean",
        "description" => "No findings."
      }
    )

    expect(disposition).to be_valid
    expect(disposition).to be_completed
    expect(disposition.finding_key).to eq("")
  end

  it "requires finding keys for actionable review findings" do
    disposition = described_class.new(
      kind: :follow_up_child,
      slot_scopes: [:repo_alpha],
      summary: "Missing coverage",
      description: "Add the missing assertion.",
      finding_key: nil
    )

    expect(disposition).not_to be_valid
  end
end
