class CreateUsersAndReaders < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    create_table :users, if_not_exists: true do |t|
      t.string :email, null: false
      t.string :name
      t.timestamps
    end

    add_index :users, :email, unique: true, algorithm: :concurrently, if_not_exists: true

    create_table :readers, if_not_exists: true do |t|
      t.bigint :user_id, null: false
      t.string :name, null: false
      t.timestamps
    end

    add_index :readers, :user_id, algorithm: :concurrently, if_not_exists: true
    add_index :readers, %i[user_id name], unique: true, algorithm: :concurrently, if_not_exists: true

    add_foreign_key :readers, :users, column: :user_id, validate: false, if_not_exists: true
  end
end

