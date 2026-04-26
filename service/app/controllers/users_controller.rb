class UsersController < ApplicationController
  def index
    result = UserService.call(action: :list)
    @users = (result.success? ? result.value : User.none).order(created_at: :desc)
  end

  def show
    load_user_for_show!
  end

  def new
    @user = User.new
  end

  def create
    result = UserService.call(action: :create, params: { attributes: user_params.to_h })

    if result.success?
      redirect_to result.value, notice: "User created."
    else
      @user = User.new(user_params)
      apply_service_errors(@user, result)
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    load_user_for_edit!
  end

  def update
    return unless load_user_for_edit!

    result = UserService.call(action: :update, params: { id: @user.id, attributes: user_params.to_h })

    if result.success?
      redirect_to result.value, notice: "User updated."
    else
      @user.assign_attributes(user_params)
      apply_service_errors(@user, result)
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    result = UserService.call(action: :destroy, params: { id: params[:id] })
    return redirect_to(users_path, alert: "User not found.") if result.failure? && result.code == :not_found

    redirect_to users_path, notice: "User deleted."
  end

  private

  def load_user_for_show!
    result = UserService.call(action: :show, params: { id: params[:id] })
    return (@user = result.value) if result.success?

    redirect_to users_path, alert: "User not found."
    false
  end

  def load_user_for_edit!
    result = UserService.call(action: :edit, params: { id: params[:id] })
    return (@user = result.value) if result.success?

    redirect_to users_path, alert: "User not found."
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

  def user_params
    params.require(:user).permit(:email, :name)
  end
end
