# frozen_string_literal: true

require "test_helper"

class BankingRollbackDemoPipelineTest < ActiveSupport::TestCase
  test "rolls back created investment on downstream failure" do
    before = Banking::Investment.count

    result = BankingRollbackDemoPipeline.call(
      params: { investment_attributes: { name: "Rollback Spec", kind: "demo", amount_cents: 1 } },
      context: { current_domain: :banking }
    )

    after = Banking::Investment.count

    assert result.failure?
    assert_equal "BankingRollbackDemoPipeline", result.meta[:pipeline_name]
    assert_equal :force_failure, result.meta[:pipeline_step]
    assert_equal before, after
  end
end
