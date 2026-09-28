class CreateApprovalQueue < ActiveRecord::Migration[8.1]
  def change
    create_table :approval_queue, id: :uuid do |t|
      t.references :order, null: false, foreign_key: true, type: :uuid, index: true

      t.string  :action_type,     null: false
      t.string  :failure_type,    null: false
      t.decimal :confidence,      precision: 5, scale: 4, null: false
      t.jsonb   :ai_diagnosis,    null: false, default: {}   # full AI proposal
      t.jsonb   :context,         null: false, default: {}   # order snapshot at request time

      t.string  :status,          null: false, default: "pending"  # pending|approved|rejected|timed_out
      t.string  :decision                                           # approved|rejected
      t.string  :decided_by                                         # operator identifier
      t.text    :decision_note
      t.datetime :decided_at

      t.datetime :expires_at, null: false                    # approval SLA timeout

      t.timestamps
    end

    add_index :approval_queue, :status
    add_index :approval_queue, :expires_at
    # Only one pending approval per order at a time
    add_index :approval_queue, [ :order_id, :status ],
              where: "status = 'pending'",
              name: "index_approval_queue_one_pending_per_order"
  end
end
