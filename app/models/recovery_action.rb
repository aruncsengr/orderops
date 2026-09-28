class RecoveryAction < ApplicationRecord
  belongs_to :order

  STATUSES = %w[pending completed failed].freeze

  # Recovery action types (REQ-06)
  TYPES = %w[
    REROUTE_RESTAURANT
    PARTIAL_REFUND
    FULL_REFUND
    ISSUE_VOUCHER
    ESCALATE_TO_HUMAN
    CANCEL_ORDER
    RETRY_DELIVERY
    CONTACT_CUSTOMER
  ].freeze

  validates :idempotency_key, presence: true, uniqueness: true
  validates :action_type,     inclusion: { in: TYPES }
  validates :status,          inclusion: { in: STATUSES }
  validates :attempt_number,  numericality: { only_integer: true, greater_than: 0 }
  validates :started_at,      presence: true

  scope :pending,   -> { where(status: "pending") }
  scope :completed, -> { where(status: "completed") }
  scope :failed,    -> { where(status: "failed") }

  def complete!(result: {})
    update!(status: "completed", completed_at: Time.current, result: result)
  end

  def fail!(reason:)
    update!(status: "failed", completed_at: Time.current, failure_reason: reason)
  end
end
