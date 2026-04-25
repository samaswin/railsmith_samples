# frozen_string_literal: true

class Comment < ApplicationRecord
  belongs_to :post, optional: true

  validates :author, presence: true
  validates :body, presence: true
end
