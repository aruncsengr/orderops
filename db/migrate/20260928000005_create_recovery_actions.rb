class CreateRecoveryActions < ActiveRecord::Migration[8.1]
  def change
    create_table :recovery_actions, id: :uuid do |t|
      t.references :order, null: false, foreign_key: true, type: :uuid, index: true

      # ADR-10: idempotency key = order_id:action_type:attempt_number
      t.string  :idempotency_key, null: false
      t.string  :action_type,     null: false
      t.integer :attempt_number,  null: false, default: 1
      t.string  :status,          null: false, default: "pending"  # pending|completed|failed

      t.jsonb   :context,         null: false, default: {}         # snapshot of order state at time of action
      t.jsonb   :result,          null: false, default: {}         # outcome data
      t.string  :failure_reason                                     # set when status=failed

      t.datetime :started_at,  null: false
      t.datetime :completed_at

      t.timestamps
    end

    # ADR-10: Database-level uniqueness enforces idempotency
    add_index :recovery_actions, :idempotency_key, unique: true
    add_index :recovery_actions, [ :order_id, :action_type, :attempt_number ], unique: true,
              name: "index_recovery_actions_on_order_action_attempt"
    add_index :recovery_actions, :status
  end
end
