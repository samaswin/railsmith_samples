require "rails_helper"

RSpec.describe Reader, type: :model do
  subject(:reader) { described_class.new(user:, name: "Reader One") }

  let(:user) { User.create!(email: "a@example.com") }

  it "is valid with a user and name" do
    expect(reader).to be_valid
  end

  it "is invalid without a name" do
    reader.name = nil
    expect(reader).not_to be_valid
    expect(reader.errors[:name]).to be_present
  end

  it "requires a user" do
    reader.user = nil
    expect(reader).not_to be_valid
  end
end

