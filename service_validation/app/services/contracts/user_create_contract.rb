# frozen_string_literal: true

module Contracts
  class UserCreateContract
    Result = Struct.new(:errors) do
      def success?
        errors.empty?
      end
    end

    def call(input)
      attrs = input.is_a?(Hash) ? input : {}
      errors = {}

      status = attrs[:status].to_s
      if status == "inactive" && attrs[:phone_number].to_s.strip.empty?
        errors[:phone_number] = [ "is required when status is inactive" ]
      end

      Result.new(errors)
    end
  end
end
