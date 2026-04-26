class ProjectsController < ApplicationController
  def index
    result = ProjectService.call(action: :list)
    @projects = (result.success? ? result.value : Project.none).order(created_at: :desc)
  end

  def show
    load_project!
  end

  def new
    @project = Project.new
  end

  def create
    result = ProjectService.call(action: :create, params: { attributes: project_params.to_h })

    if result.success?
      redirect_to result.value, notice: "Project created."
    else
      @project = Project.new(project_params)
      apply_service_errors(@project, result)
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    load_project!
  end

  def update
    return unless load_project!

    result = ProjectService.call(action: :update, params: { id: @project.id, attributes: project_params.to_h })

    if result.success?
      redirect_to result.value, notice: "Project updated."
    else
      @project.assign_attributes(project_params)
      apply_service_errors(@project, result)
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    result = ProjectService.call(action: :destroy, params: { id: params[:id] })
    return redirect_to(projects_path, alert: "Project not found.") if result.failure? && result.code == :not_found

    redirect_to projects_path, notice: "Project deleted."
  end

  private

  def load_project!
    result = ProjectService.call(action: :find, params: { id: params[:id] })
    return (@project = result.value) if result.success?

    redirect_to projects_path, alert: "Project not found."
    false
  end

  def apply_service_errors(record, result)
    return unless result.failure?

    errors = result.error&.details&.fetch(:errors, nil)
    return unless errors.is_a?(Hash)

    errors.each do |attribute, messages|
      Array(messages).each { |message| record.errors.add(attribute, message) }
    end
  end

  def project_params
    params.require(:project).permit(:name)
  end
end
