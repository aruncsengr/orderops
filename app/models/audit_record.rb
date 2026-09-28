class AuditRecord < ApplicationRecord
  belongs_to :order

  ACTOR_SYSTEM    = "system"
  ACTOR_AI_AGENT  = "ai_agent"
  ACTOR_SIMULATOR = "simulator"

  def self.actor_human(operator_id)
    "human:#{operator_id}"
  end

  validates :event_type,      presence: true
  validates :subsystem,       presence: true
  validates :actor,           presence: true
  validates :occurred_at,     presence: true
  validates :sequence_number, presence: true,
                              numericality: { only_integer: true, greater_than: 0 }

  # Ordered query used by AuditTrail service and dashboard (REQ-11, AC-11.6)
  scope :for_order, ->(order_id) {
    where(order_id: order_id).order(:sequence_number)
  }
  scope :chronological, -> { order(:sequence_number) }

  # -----------------------------------------------------------------------
  # Append-only enforcement at the application layer (ADR-15)
  # The PostgreSQL trigger is the hard enforcement; this is belt-and-suspenders.
  # -----------------------------------------------------------------------
  before_update { raise ActiveRecord::ReadOnlyRecord, "audit_records is append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "audit_records is append-only" }
end
