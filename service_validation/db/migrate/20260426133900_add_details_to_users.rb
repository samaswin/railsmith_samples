# frozen_string_literal: true

class AddDetailsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :first_name, :string
    add_column :users, :last_name, :string
    add_column :users, :date_of_joining, :date
    add_column :users, :phone_number, :string
  end
end
