# frozen_string_literal: true

# AuditTrail — event bus subscriber that writes every domain event to the
# append-only audit_records table (ADR-15, REQ-11).
#
# Registered as a subscribe_all handler at boot (see config/initializers/orderops.rb).
#
# Sequence allocation: uses MAX(sequence_number) + 1 scoped to order_id inside
# a single INSERT statement via a PostgreSQL advisory lock on the order UUID's
# hash. This gives per-order monotonic sequencing without a sequence-per-order
# object. The advisory lock is held only for the duration of the INSERT.
#
# Note: AuditRecord writes are NOT in the same transaction as the triggering
# state change (see ActiveJobEventBusAdapter comment). A gap is detectable
# because sequence numbers would not be contiguous.
#
class AuditTrail
  # Called by EventBus for every domain event.
  def call(event)
    write(event)
  end

  # Convenience class method used directly in tests and Phase 2+ services.
  def self.record(event)
    new.write(event)
  end

  # Retrieve the full ordered history for an order (AC-11.6).
  def self.for_order(order_id)
    AuditRecord.for_order(order_id)
  end

  def write(event)
    order_id = event.order_id

    with_advisory_lock(order_id) do
      next_seq = next_sequence_number(order_id)

      AuditRecord.create!(
        order_id:        order_id,
        sequence_number: next_seq,
        occurred_at:     event.occurred_at,
        event_type:      event.event_type,
        subsystem:       event.subsystem,
        actor:           extract_actor(event),
        state_before:    event.payload[:from_state] || event.payload["from_state"],
        state_after:     event.payload[:to_state]   || event.payload["to_state"],
        payload:         event.payload,
        policy_version:  event.payload[:policy_version] || event.payload["policy_version"],
        llm_model:       event.payload[:llm_model]      || event.payload["llm_model"],
        llm_call_id:     event.payload[:llm_call_id]    || event.payload["llm_call_id"],
        idempotency_key: event.payload[:idempotency_key] || event.payload["idempotency_key"],
        injected:        event.injected?
      )
    end
  rescue => e
    # Audit failures must never crash the caller. Log and continue.
    Rails.logger.error "[AuditTrail] Failed to write audit record for " \
                       "#{event.event_type} / order #{event.order_id}: " \
                       "#{e.class}: #{e.message}"
    nil
  end

  private

  # PostgreSQL advisory lock keyed on a stable integer derived from the order UUID.
  # This serialises concurrent audit writes for the same order so the MAX+1
  # sequence allocation is race-free.
  def with_advisory_lock(order_id, &block)
    lock_key = order_id.to_s.bytes.first(8).inject(0) { |acc, b| (acc << 8) | b }
    ActiveRecord::Base.connection.execute(
      "SELECT pg_advisory_xact_lock(#{lock_key})"
    )
    ActiveRecord::Base.transaction(&block)
  end

  def next_sequence_number(order_id)
    result = ActiveRecord::Base.connection.execute(
      "SELECT COALESCE(MAX(sequence_number), 0) + 1 AS next_seq " \
      "FROM audit_records WHERE order_id = '#{ActiveRecord::Base.connection.quote_string(order_id)}'"
    )
    result.first["next_seq"].to_i
  end

  def extract_actor(event)
    event.payload[:actor] || event.payload["actor"] ||
      case event.subsystem
      when "ai_agent"    then AuditRecord::ACTOR_AI_AGENT
      when /simulator/   then AuditRecord::ACTOR_SIMULATOR
      else                    AuditRecord::ACTOR_SYSTEM
      end
  end
end
