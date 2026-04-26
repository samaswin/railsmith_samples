require "rails_helper"

RSpec.describe User, type: :model do
  subject(:user) { described_class.new(email: "a@example.com", name: "Alice") }

  it "is valid with an email" do
    expect(user).to be_valid
  end

  it "is invalid without an email" do
    user.email = nil
    expect(user).not_to be_valid
    expect(user.errors[:email]).to be_present
  end

  it "enforces unique emails" do
    described_class.create!(email: "a@example.com")
    expect(user).not_to be_valid
    expect(user.errors[:email]).to be_present
  end
end

