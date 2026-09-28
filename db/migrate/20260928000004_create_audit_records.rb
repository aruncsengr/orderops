class CreateAuditRecords < ActiveRecord::Migration[8.1]
  def up
    create_table :audit_records, id: :uuid do |t|
      t.references :order, null: false, foreign_key: true, type: :uuid, index: true

      t.integer  :sequence_number, null: false          # per-order monotonic (ADR-15)
      t.datetime :occurred_at,     null: false, precision: 6  # UTC, microsecond
      t.string   :event_type,      null: false
      t.string   :subsystem,       null: false
      t.string   :actor,           null: false          # system|ai_agent|human:{id}|simulator

      t.string   :state_before
      t.string   :state_after

      t.jsonb    :payload,         null: false, default: {}

      t.string   :policy_version                        # set when policy evaluation occurred
      t.string   :llm_model                             # set for AI invocations
      t.string   :llm_call_id                           # set for AI invocations
      t.string   :idempotency_key                       # set for executed recovery actions
      t.boolean  :injected,        null: false, default: false

      # No updated_at — append-only; created_at only
      t.datetime :created_at, null: false
    end

    add_index :audit_records, [ :order_id, :sequence_number ], unique: true
    add_index :audit_records, :event_type
    add_index :audit_records, :occurred_at
    add_index :audit_records, :injected

    # ADR-15: PostgreSQL trigger prevents UPDATE or DELETE on audit_records
    execute <<~SQL
      CREATE OR REPLACE FUNCTION audit_records_immutable()
      RETURNS TRIGGER LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'audit_records is append-only: % on row id=% is not allowed',
          TG_OP, COALESCE(OLD.id::text, 'unknown');
      END;
      $$;

      CREATE TRIGGER audit_records_no_update
        BEFORE UPDATE ON audit_records
        FOR EACH ROW EXECUTE FUNCTION audit_records_immutable();

      CREATE TRIGGER audit_records_no_delete
        BEFORE DELETE ON audit_records
        FOR EACH ROW EXECUTE FUNCTION audit_records_immutable();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS audit_records_no_update ON audit_records;
      DROP TRIGGER IF EXISTS audit_records_no_delete ON audit_records;
      DROP FUNCTION IF EXISTS audit_records_immutable();
    SQL
    drop_table :audit_records
  end
end
