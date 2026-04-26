require "rails_helper"

RSpec.describe UserService, type: :service do
  describe "associations" do
    it "can create a reader through nested write (service-to-service)" do
      user = User.create!(email: "a@example.com")

      result =
        described_class.call(
          action: :update,
          params: {
            id: user.id,
            attributes: {},
            readers: [ { attributes: { name: "Reader One" } } ]
          }
        )

      expect(result).to be_success
      expect(user.reload.readers.pluck(:name)).to eq([ "Reader One" ])
    end
  end

  describe "eager loading" do
    it "preloads readers on show to avoid N+1" do
      user = User.create!(email: "a@example.com")
      Reader.create!(user:, name: "Reader One")
      Reader.create!(user:, name: "Reader Two")

      result = described_class.call(action: :show, params: { id: user.id })
      expect(result).to be_success

      loaded_user = result.value

      queries = count_sql_queries { loaded_user.readers.to_a }
      expect(queries).to eq(0)
    end
  end
end
