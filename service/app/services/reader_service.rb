# frozen_string_literal: true

class ReaderService < Railsmith::BaseService
  model(Reader)

  belongs_to :user, service: UserService
  includes :user
end

