# frozen_string_literal: true

require "test_helper"

class BankingCreateInvestmentPipelineTest < ActiveSupport::TestCase
  test "creates investment with banking context" do
    result = BankingCreateInvestmentPipeline.call(
      params: { investment_attributes: { name: "Spec", kind: "stock", amount_cents: 100 } },
      context: { current_domain: :banking }
    )

    assert result.success?
    assert_instance_of Banking::Investment, result.value
    assert_equal "Spec", result.value.name
  end

  test "emits cross-domain warning when context mismatches" do
    events = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      events << payload
    end

    ActiveSupport::Notifications.subscribed(callback, "cross_domain.warning.railsmith") do
      result = BankingCreateInvestmentPipeline.call(
        params: { investment_attributes: { name: "Spec2", kind: "bond", amount_cents: 1 } },
        context: { current_domain: :medical }
      )

      assert result.success?
    end

    assert_equal 1, events.size
    assert_equal :medical, events[0][:context_domain]
    assert_equal :banking, events[0][:service_domain]
  end
end
