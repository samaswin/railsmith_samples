require "rails_helper"

RSpec.describe Project, type: :model do
  subject(:project) { described_class.new(name: "Alpha") }

  it "is valid with a name" do
    expect(project).to be_valid
  end

  it "is invalid without a name" do
    project.name = nil
    expect(project).not_to be_valid
    expect(project.errors[:name]).to be_present
  end

  it "enforces unique names" do
    described_class.create!(name: "Alpha")
    expect(project).not_to be_valid
    expect(project.errors[:name]).to be_present
  end
end
