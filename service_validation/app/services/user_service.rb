# frozen_string_literal: true

class UserService < Railsmith::BaseService
  model(User)

  input :email, String, required: true, transform: ->(v) { v.strip.downcase }
  input :first_name, String, required: true, transform: ->(v) { v.strip }
  input :last_name, String, required: true, transform: ->(v) { v.strip }
  input :date_of_joining, :date_blank_to_nil, required: true
  input :status, String, in: %w[active inactive], default: "active"
  input :phone_number, String, default: nil, transform: ->(v) { v.strip }
  input :name, String, default: nil, transform: ->(v) { v.strip }

  def create
    val = validate(params[:attributes], contract: Contracts::UserCreateContract.new)
    return val if val.failure?

    super
  end

  def show
    find_one
  end

  private

  def find_one
    model_klass = model_class
    return missing_model_class_result unless model_klass

    find_record(model_klass, record_id)
  end
end
