# frozen_string_literal: true

# Base class for all OrderOps domain events (REQ-02, ADR-03).
#
# Every event is an immutable value object. Events are NOT ActiveRecord models.
# They are serialised to JSON for delivery via the EventBus and for storage in
# audit_records.payload.
#
# Required fields (AC-02.2):
#   event_id        – UUID (deduplication key, AC-02.3)
#   event_type      – dot-notation string, e.g. "order.state_changed"
#   order_id        – UUID of the affected order
#   sequence_number – per-order monotonic integer (ADR-03)
#   occurred_at     – UTC Time (microsecond precision)
#   subsystem       – originating component name
#   payload         – Hash with event-specific data
#
class DomainEvent
  attr_reader :event_id, :event_type, :order_id, :sequence_number,
              :occurred_at, :subsystem, :payload

  def initialize(
    event_type:,
    order_id:,
    subsystem:,
    payload: {},
    sequence_number: nil,
    occurred_at: nil,
    event_id: nil
  )
    @event_id        = event_id || SecureRandom.uuid
    @event_type      = event_type.to_s
    @order_id        = order_id.to_s
    @subsystem       = subsystem.to_s
    @payload         = payload.freeze
    @sequence_number = sequence_number
    @occurred_at     = occurred_at || Time.current

    freeze
  end

  # Serialise to a plain Hash for JSON storage / job arguments
  def to_h
    {
      event_id:        event_id,
      event_type:      event_type,
      order_id:        order_id,
      sequence_number: sequence_number,
      occurred_at:     occurred_at.iso8601(6),
      subsystem:       subsystem,
      payload:         payload
    }
  end

  def to_json(*)
    to_h.to_json
  end

  # Reconstruct from a serialised Hash (e.g. from an ActiveJob argument)
  def self.from_h(hash)
    h = hash.transform_keys(&:to_sym)
    new(
      event_id:        h[:event_id],
      event_type:      h[:event_type],
      order_id:        h[:order_id],
      subsystem:       h[:subsystem],
      payload:         h[:payload] || {},
      sequence_number: h[:sequence_number],
      occurred_at:     h[:occurred_at] ? Time.parse(h[:occurred_at]) : Time.current
    )
  end

  def injected?
    payload[:injected] == true || payload["injected"] == true
  end

  def ==(other)
    other.is_a?(DomainEvent) && event_id == other.event_id
  end
  alias eql? ==

  def hash
    event_id.hash
  end
end
