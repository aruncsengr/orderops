class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders, id: :uuid do |t|
      t.references :customer,   null: false, foreign_key: true, type: :uuid
      t.references :restaurant,             foreign_key: true, type: :uuid  # nullable until assigned

      t.string  :state,         null: false, default: "pending"
      t.integer :lock_version,  null: false, default: 0           # Rails optimistic locking (ADR-04)

      t.jsonb   :items,         null: false, default: []          # [{name, quantity, unit_price, currency}]
      t.decimal :order_total,   null: false, precision: 10, scale: 2
      t.string  :currency,      null: false, default: "USD", limit: 3

      t.jsonb   :delivery_address, null: false, default: {}       # {street, city, postcode, lat, lng}
      t.string  :payment_intent_id                                 # simulator payment reference

      t.datetime :sla_started_at                                   # when current SLA phase began
      t.string   :sla_phase                                        # current SLA phase name
      t.string   :sla_status, null: false, default: "ok"          # ok | warning | breached

      t.string  :cuisine_type, null: false                        # for routing

      # uuid[] for rejected restaurant IDs — PostgreSQL native array
      t.column :rejected_restaurant_ids, :uuid, array: true, null: false, default: []

      t.integer :reroute_attempt_count, null: false, default: 0   # guardrail counter

      t.jsonb   :customer_recovery_preferences, default: nil      # {preferred_action, contact_method}

      t.timestamps
    end

    add_index :orders, :state
    add_index :orders, :sla_status
    add_index :orders, :sla_started_at
    add_index :orders, [:state, :sla_status]
  end
end
