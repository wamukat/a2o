# frozen_string_literal: true

RSpec.describe "A3 version" do
  it "matches the A2O 0.5.10 release version" do
    expect(A3::VERSION).to eq("0.5.10")
  end
end
