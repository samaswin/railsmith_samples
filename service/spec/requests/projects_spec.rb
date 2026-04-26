require "rails_helper"

RSpec.describe "Projects", type: :request do
  describe "GET /projects" do
    it "renders successfully" do
      get projects_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /projects/:id" do
    it "renders successfully" do
      project = Project.create!(name: "Alpha")

      get project_path(project)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /projects/new" do
    it "renders successfully" do
      get new_project_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /projects" do
    it "creates a project and redirects" do
      expect do
        post projects_path, params: { project: { name: "Alpha" } }
      end.to change(Project, :count).by(1)

      expect(response).to redirect_to(project_path(Project.last))
      follow_redirect!
      expect(response.body).to include("Project created.")
    end

    it "re-renders on validation failure" do
      expect do
        post projects_path, params: { project: { name: "" } }
      end.not_to change(Project, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Please fix these errors")
    end
  end

  describe "GET /projects/:id/edit" do
    it "renders successfully" do
      project = Project.create!(name: "Alpha")

      get edit_project_path(project)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "PATCH /projects/:id" do
    it "updates and redirects" do
      project = Project.create!(name: "Alpha")

      patch project_path(project), params: { project: { name: "Beta" } }
      expect(response).to redirect_to(project_path(project))

      project.reload
      expect(project.name).to eq("Beta")
    end

    it "re-renders on validation failure" do
      project = Project.create!(name: "Alpha")

      patch project_path(project), params: { project: { name: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(project.reload.name).to eq("Alpha")
    end
  end

  describe "DELETE /projects/:id" do
    it "deletes and redirects" do
      project = Project.create!(name: "Alpha")

      expect do
        delete project_path(project)
      end.to change(Project, :count).by(-1)

      expect(response).to redirect_to(projects_path)
    end
  end
end
