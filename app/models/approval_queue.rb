class ApprovalQueue < ApplicationRecord
  belongs_to :order

  STATUSES   = %w[pending approved rejected timed_out].freeze
  DECISIONS  = %w[approved rejected].freeze

  validates :action_type,  presence: true
  validates :failure_type, presence: true
  validates :confidence,   numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :status,       inclusion: { in: STATUSES }
  validates :expires_at,   presence: true

  scope :pending,  -> { where(status: "pending") }
  scope :expired,  -> { where(status: "pending").where("expires_at < ?", Time.current) }

  def decide!(decision:, decided_by:, note: nil)
    raise ArgumentError, "Invalid decision: #{decision}" unless DECISIONS.include?(decision.to_s)
    raise ArgumentError, "Already decided" unless status == "pending"

    update!(
      status:       decision.to_s,
      decision:     decision.to_s,
      decided_by:   decided_by,
      decision_note: note,
      decided_at:   Time.current
    )
  end

  def pending?
    status == "pending"
  end

  def approved?
    decision == "approved"
  end
end
