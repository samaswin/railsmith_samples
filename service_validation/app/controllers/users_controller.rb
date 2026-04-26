# frozen_string_literal: true

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
      @service_validation_errors, @model_validation_errors = split_validation_errors(result)
      render :new, status: :unprocessable_entity
    end
  end

  private

  def load_user_for_show!
    result = UserService.call(action: :show, params: { id: params[:id] })
    return (@user = result.value) if result.success?

    redirect_to users_path, alert: "User not found."
    false
  end

  def split_validation_errors(result)
    return [ {}, {} ] unless result.failure?

    errors = result.error&.details&.fetch(:errors, nil)
    return [ {}, {} ] unless errors.is_a?(Hash)

    service_errors = {}
    model_errors = {}

    errors.each do |attribute, messages|
      if messages.is_a?(Array)
        model_errors[attribute] = messages
      else
        service_errors[attribute] = Array(messages)
      end
    end

    [ service_errors, model_errors ]
  end

  def user_params
    params.require(:user).permit(:email, :name, :first_name, :last_name, :date_of_joining, :phone_number)
  end
end
