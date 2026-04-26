require "rails_helper"

RSpec.describe "Users", type: :request do
  describe "GET /users" do
    it "renders successfully" do
      get users_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /users/:id" do
    it "renders successfully" do
      user = User.create!(email: "a@example.com")
      Reader.create!(user:, name: "Reader One")

      get user_path(user)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Readers")
      expect(response.body).to include("Reader One")
    end
  end

  describe "POST /users/:user_id/readers" do
    it "creates a reader through UserService and redirects" do
      user = User.create!(email: "a@example.com")

      expect do
        post user_readers_path(user), params: { reader: { name: "Reader One" } }
      end.to change(Reader, :count).by(1)

      expect(response).to redirect_to(user_path(user))
    end
  end
end

