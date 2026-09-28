class Restaurant < ApplicationRecord
  has_many :orders, dependent: :restrict_with_error

  validates :name,         presence: true
  validates :cuisine_type, presence: true
  validates :max_capacity, numericality: { greater_than: 0 }
  validates :current_queue, numericality: { greater_than_or_equal_to: 0 }
  validates :failure_rate, numericality: {
    greater_than_or_equal_to: 0.0,
    less_than_or_equal_to: 1.0
  }

  scope :available, -> { where(available: true) }
  scope :by_cuisine, ->(type) { where(cuisine_type: type) }
  scope :with_capacity, -> { where("current_queue < max_capacity") }

  def at_capacity?
    current_queue >= max_capacity
  end
end
