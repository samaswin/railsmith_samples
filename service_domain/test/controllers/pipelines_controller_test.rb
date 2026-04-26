# frozen_string_literal: true

require "test_helper"

class PipelinesControllerTest < ActionDispatch::IntegrationTest
  test "GET /pipelines renders" do
    get pipelines_url
    assert_response :success
  end

  test "POST /pipelines/run runs pipeline and renders result" do
    post run_pipelines_url, params: {
      pipeline_key: "Banking: Create Investment",
      context_domain: "banking",
      investment_attributes: { name: "UI Spec", kind: "stock", amount_cents: 10 }
    }

    assert_response :success
    assert_includes @response.body, "Result"
    assert_includes @response.body, "success?"
    assert_includes @response.body, "true"
  end

  test "POST /pipelines/run shows cross-domain warnings when mismatch" do
    post run_pipelines_url, params: {
      pipeline_key: "Banking: Create Investment",
      context_domain: "medical",
      investment_attributes: { name: "UI Spec2", kind: "bond", amount_cents: 1 }
    }

    assert_response :success
    assert_includes @response.body, "Cross-domain warnings"
  end
end
