# frozen_string_literal: true

class UserService < Railsmith::BaseService
  model(User)

  has_many :readers, service: ReaderService, dependent: :destroy

  includes :readers, only: %i[list show]

  def show
    find_one
  end

  def edit
    find_one
  end

  private

  def find_one
    model_klass = model_class
    return missing_model_class_result unless model_klass

    find_record(model_klass, record_id)
  end
end
