class ValidateUsersAndReadersForeignKeys < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :readers, :users, column: :user_id
  end
end

