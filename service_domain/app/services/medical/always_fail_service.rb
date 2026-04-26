# frozen_string_literal: true

module Medical
  class AlwaysFailService < Railsmith::BaseService
    domain :medical

    def fail
      Railsmith::Result.failure(code: :unexpected, message: "Forced failure (rollback demo)")
    end
  end
end
