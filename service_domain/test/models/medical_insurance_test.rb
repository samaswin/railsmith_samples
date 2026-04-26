# frozen_string_literal: true

require "test_helper"

class MedicalInsuranceTest < ActiveSupport::TestCase
  test "validations" do
    ins = Medical::Insurance.new(provider: "ACME", premium_cents: 0)
    assert_not ins.valid?
    assert_includes ins.errors[:policy_number], "can't be blank"
  end
end
