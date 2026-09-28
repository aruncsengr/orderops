class CreateRestaurants < ActiveRecord::Migration[8.1]
  def change
    create_table :restaurants, id: :uuid do |t|
      t.string  :name,          null: false
      t.string  :cuisine_type,  null: false
      t.decimal :latitude,      precision: 10, scale: 6
      t.decimal :longitude,     precision: 10, scale: 6
      t.integer :max_capacity,  null: false, default: 10
      t.integer :current_queue, null: false, default: 0
      t.boolean :available,     null: false, default: true
      t.decimal :failure_rate,  precision: 5, scale: 4, null: false, default: 0.0
      t.jsonb   :metadata,      null: false, default: {}

      t.timestamps
    end

    add_index :restaurants, :cuisine_type
    add_index :restaurants, :available
  end
end
