class ReadersController < ApplicationController
  def index
    user = User.find_by(id: params[:user_id])
    return redirect_to(users_path, alert: "User not found.") if user.blank?

    @user = user
    @readers = user.readers.order(created_at: :desc)
  end

  def show
    load_reader!
  end

  def new
    user = User.find_by(id: params[:user_id])
    return redirect_to(users_path, alert: "User not found.") if user.blank?

    @user = user
    @reader = user.readers.build
  end

  def create
    user = User.find_by(id: params[:user_id])
    return redirect_to(users_path, alert: "User not found.") if user.blank?

    result =
      UserService.call(
        action: :update,
        params: {
          id: user.id,
          attributes: {},
          readers: [{ attributes: reader_params.to_h }]
        }
      )

    if result.success?
      redirect_to user_path(user), notice: "Reader created."
    else
      @user = user
      @reader = user.readers.build(reader_params)
      apply_service_errors(@reader, result)
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    load_reader!
  end

  def update
    return unless load_reader!

    result = ReaderService.call(action: :update, params: { id: @reader.id, attributes: reader_params.to_h })

    if result.success?
      redirect_to reader_path(result.value), notice: "Reader updated."
    else
      @reader.assign_attributes(reader_params)
      apply_service_errors(@reader, result)
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    user_id = params[:user_id]
    result = ReaderService.call(action: :destroy, params: { id: params[:id] })
    return redirect_to(users_path, alert: "Reader not found.") if result.failure? && result.code == :not_found

    if user_id.present?
      redirect_to user_path(user_id), notice: "Reader deleted."
    else
      redirect_to users_path, notice: "Reader deleted."
    end
  end

  private

  def load_reader!
    result = ReaderService.call(action: :find, params: { id: params[:id] })
    return (@reader = result.value) if result.success?

    redirect_to users_path, alert: "Reader not found."
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

  def reader_params
    params.require(:reader).permit(:name)
  end
end

