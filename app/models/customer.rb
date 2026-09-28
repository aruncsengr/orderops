class Customer < ApplicationRecord
  has_many :orders, dependent: :restrict_with_error

  validates :name,  presence: true
  validates :email, presence: true, uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP }
end
