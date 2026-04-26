# frozen_string_literal: true

module Banking
  class InvestmentPipelineService < Railsmith::BaseService
    domain :banking
    model(Banking::Investment)

    def create_with_id
      result = Banking::InvestmentService.call(action: :create, params: params, context: context)
      return result if result.failure?

      Railsmith::Result.success(value: { id: result.value.id })
    end
  end
end
