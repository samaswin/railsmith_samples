# frozen_string_literal: true

class User < ApplicationRecord
  EMAIL_REGEX = /\A[^@\s]+@[^@\s]+\z/

  # Service-layer (Railsmith inputs) enforces presence/type.
  # Model-layer enforces persistence-level constraints and business rules.
  validates :email, uniqueness: true, allow_blank: true
  validates :email, format: { with: EMAIL_REGEX }, allow_blank: true
  validate :phone_number_has_valid_length
  validate :date_of_joining_cannot_be_in_future

  def full_name
    [ first_name, last_name ].compact_blank.join(" ")
  end

  private

  def date_of_joining_cannot_be_in_future
    return if date_of_joining.blank?
    return unless date_of_joining > Date.current

    errors.add(:date_of_joining, "cannot be in the future")
  end

  def phone_number_has_valid_length
    return if phone_number.blank?

    digits = phone_number.to_s.gsub(/\D/, "")
    return if digits.length.between?(10, 15)

    errors.add(:phone_number, "is invalid")
  end
end
