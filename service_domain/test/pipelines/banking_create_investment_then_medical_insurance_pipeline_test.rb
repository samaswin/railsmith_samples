# frozen_string_literal: true

require "test_helper"
require "securerandom"

class BankingCreateInvestmentThenMedicalInsurancePipelineTest < ActiveSupport::TestCase
  test "creates both records and emits cross-domain warning for medical step under banking context" do
    events = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      events << payload
    end

    result = nil
    ActiveSupport::Notifications.subscribed(callback, "cross_domain.warning.railsmith") do
      result = BankingCreateInvestmentThenMedicalInsurancePipeline.call(
        params: {
          investment_attributes: { name: "Spec3", kind: "fund", amount_cents: 10 },
          insurance_attributes: { provider: "ACME", policy_number: "SPEC-#{SecureRandom.hex(4)}", premium_cents: 1 }
        },
        context: { current_domain: :banking }
      )
    end

    assert result.success?
    assert_instance_of Medical::Insurance, result.value

    mismatch = events.find { |e| e[:service] == "Medical::InsuranceService" }
    assert mismatch, "Expected a cross-domain warning for Medical::InsuranceService"
    assert_equal :banking, mismatch[:context_domain]
    assert_equal :medical, mismatch[:service_domain]
  end
end
