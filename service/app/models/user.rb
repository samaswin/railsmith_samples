class User < ApplicationRecord
  has_many :readers, dependent: :destroy

  validates :email, presence: true, uniqueness: true
end

