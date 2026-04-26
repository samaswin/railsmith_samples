# frozen_string_literal: true

require "test_helper"

class BankingInvestmentTest < ActiveSupport::TestCase
  test "validations" do
    inv = Banking::Investment.new(kind: "stock", amount_cents: 0)
    assert_not inv.valid?
    assert_includes inv.errors[:name], "can't be blank"
  end
end
