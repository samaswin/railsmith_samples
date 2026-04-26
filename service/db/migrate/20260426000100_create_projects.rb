class CreateProjects < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    create_table :projects do |t|
      t.string :name, null: false
      t.timestamps
    end

    add_index :projects, :name, unique: true, algorithm: :concurrently
  end
end

