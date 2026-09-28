class Order < ApplicationRecord
  # ADR-04: optimistic locking — lock_version column auto-incremented by Rails
  # No explicit `self.locking_column` needed; Rails detects `lock_version` by convention.

  belongs_to :customer
  belongs_to :restaurant, optional: true

  has_many :audit_records, dependent: :restrict_with_error
  has_many :recovery_actions, dependent: :restrict_with_error
  has_many :approval_queue_entries, class_name: "ApprovalQueue", dependent: :restrict_with_error

  # -----------------------------------------------------------------------
  # State constants (REQ-01 / ADR-04)
  # Using plain string values, not Rails enum macro, to prevent enum's
  # update_column bypass of OrderStateMachine.
  # -----------------------------------------------------------------------
  STATES = %w[
    pending
    assigned
    accepted
    preparing
    ready_for_pickup
    in_delivery
    delivered
    failed
    cancelled
    recovered
    pending_approval
    recovering
  ].freeze

  TERMINAL_STATES = %w[delivered cancelled recovered].freeze

  # Each state maps to the set of valid target states
  TRANSITIONS = {
    "pending"          => %w[assigned cancelled],
    "assigned"         => %w[accepted failed pending],
    "accepted"         => %w[preparing failed],
    "preparing"        => %w[ready_for_pickup failed],
    "ready_for_pickup" => %w[in_delivery failed],
    "in_delivery"      => %w[delivered failed],
    "failed"           => %w[pending_approval recovering cancelled],
    "pending_approval" => %w[recovering cancelled],
    "recovering"       => %w[recovered failed]
  }.freeze

  # -----------------------------------------------------------------------
  # Validations
  # -----------------------------------------------------------------------
  validates :state, inclusion: { in: STATES }
  validates :order_total, numericality: { greater_than_or_equal_to: 0 }
  validates :currency,    length: { is: 3 }
  validates :cuisine_type, presence: true
  validates :items,        presence: true
  validate  :delivery_address_present

  # -----------------------------------------------------------------------
  # Scopes
  # -----------------------------------------------------------------------
  scope :active,    -> { where.not(state: TERMINAL_STATES) }
  scope :terminal,  -> { where(state: TERMINAL_STATES) }
  scope :in_state,  ->(s) { where(state: s) }
  scope :needing_sla_check, -> {
    where.not(state: TERMINAL_STATES)
         .where.not(sla_started_at: nil)
  }

  # -----------------------------------------------------------------------
  # State helpers
  # -----------------------------------------------------------------------
  def terminal?
    TERMINAL_STATES.include?(state)
  end

  def transition_allowed_to?(target)
    TRANSITIONS.fetch(state, []).include?(target.to_s)
  end

  # -----------------------------------------------------------------------
  # Private
  # -----------------------------------------------------------------------
  private

  def delivery_address_present
    if delivery_address.blank? || !delivery_address.is_a?(Hash)
      errors.add(:delivery_address, "must be a non-empty hash")
    end
  end
end
