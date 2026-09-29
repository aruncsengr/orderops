# frozen_string_literal: true

# DispatchDomainEventJob — relay job enqueued by ActiveJobEventBusAdapter.
#
# In V1 this job is a lightweight hook for future async-only subscribers.
# All in-process handlers (AuditTrail, etc.) are already called synchronously
# by the adapter before this job is enqueued. This job exists so that:
#   1. The EventBus interface is durable — if a future subsystem needs
#      background processing it subscribes here without changing the adapter.
#   2. The Solid Queue job log gives operators visibility into every domain
#      event that was published (useful for debugging).
#
# The job is idempotent: if enqueued twice with the same event_id, the second
# execution is a no-op (no registered async handlers in V1).
#
class DispatchDomainEventJob < ApplicationJob
  queue_as :events

  # event_hash is a plain Hash produced by DomainEvent#to_h — safe to serialise
  # as a JSON argument by Solid Queue.
  def perform(event_hash)
    event = DomainEvent.from_h(event_hash)

    Rails.logger.debug "[DispatchDomainEventJob] Relayed #{event.event_type} " \
                       "for order #{event.order_id} (seq=#{event.sequence_number})"

    # V1: no async-only subscribers registered yet.
    # Future async subscribers will be called here.
  end
end
