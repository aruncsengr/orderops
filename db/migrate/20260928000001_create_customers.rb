class CreateCustomers < ActiveRecord::Migration[8.1]
  def change
    create_table :customers, id: :uuid do |t|
      t.string :name, null: false
      t.string :email, null: false
      t.string :phone
      t.jsonb  :contact_preferences, null: false, default: {}

      t.timestamps
    end

    add_index :customers, :email, unique: true
  end
end
