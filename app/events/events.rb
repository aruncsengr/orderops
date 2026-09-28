# frozen_string_literal: true

# Concrete domain event types (REQ-02).
# Each subclass fixes the event_type and optionally adds typed payload accessors.
# All events remain immutable value objects — no ActiveRecord dependency.

# ---------------------------------------------------------------------------
# Order lifecycle events
# ---------------------------------------------------------------------------

class Events::OrderCreated < DomainEvent
  def initialize(order_id:, subsystem: "order_state_machine", payload: {})
    super(event_type: "order.created", order_id: order_id, subsystem: subsystem, payload: payload)
  end
end

class Events::OrderStateChanged < DomainEvent
  def initialize(order_id:, from_state:, to_state:, actor: "system", subsystem: "order_state_machine", payload: {})
    super(
      event_type: "order.state_changed",
      order_id:   order_id,
      subsystem:  subsystem,
      payload:    payload.merge(from_state: from_state, to_state: to_state, actor: actor)
    )
  end

  def from_state = payload[:from_state] || payload["from_state"]
  def to_state   = payload[:to_state]   || payload["to_state"]
end

# ---------------------------------------------------------------------------
# Restaurant events
# ---------------------------------------------------------------------------

class Events::RestaurantAccepted < DomainEvent
  def initialize(order_id:, restaurant_id:, subsystem: "restaurant_simulator", payload: {})
    super(event_type: "restaurant.accepted", order_id: order_id, subsystem: subsystem,
          payload: payload.merge(restaurant_id: restaurant_id))
  end
end

class Events::RestaurantRejected < DomainEvent
  def initialize(order_id:, restaurant_id:, reason: nil, subsystem: "restaurant_simulator", payload: {})
    super(event_type: "restaurant.rejected", order_id: order_id, subsystem: subsystem,
          payload: payload.merge(restaurant_id: restaurant_id, reason: reason))
  end
end

class Events::RestaurantUnavailable < DomainEvent
  def initialize(order_id:, restaurant_id:, reason: nil, subsystem: "restaurant_simulator", payload: {})
    super(event_type: "restaurant.unavailable", order_id: order_id, subsystem: subsystem,
          payload: payload.merge(restaurant_id: restaurant_id, reason: reason))
  end
end

# ---------------------------------------------------------------------------
# Failure events
# ---------------------------------------------------------------------------

class Events::InventoryFailure < DomainEvent
  def initialize(order_id:, description:, subsystem: "inventory_simulator", payload: {})
    super(event_type: "inventory.failure", order_id: order_id, subsystem: subsystem,
          payload: payload.merge(failure_type: "INVENTORY_FAILURE", description: description))
  end
end

class Events::KitchenDelay < DomainEvent
  def initialize(order_id:, elapsed_seconds:, subsystem: "restaurant_simulator", payload: {})
    super(event_type: "kitchen.delay", order_id: order_id, subsystem: subsystem,
          payload: payload.merge(failure_type: "KITCHEN_DELAY", elapsed_seconds: elapsed_seconds))
  end
end

class Events::KitchenFailure < DomainEvent
  def initialize(order_id:, description:, subsystem: "restaurant_simulator", payload: {})
    super(event_type: "kitchen.failure", order_id: order_id, subsystem: subsystem,
          payload: payload.merge(failure_type: "KITCHEN_FAILURE", description: description))
  end
end

class Events::DeliveryDelay < DomainEvent
  def initialize(order_id:, elapsed_seconds:, subsystem: "delivery_simulator", payload: {})
    super(event_type: "delivery.delay", order_id: order_id, subsystem: subsystem,
          payload: payload.merge(failure_type: "DELIVERY_DELAY", elapsed_seconds: elapsed_seconds))
  end
end

class Events::DeliveryFailure < DomainEvent
  def initialize(order_id:, description:, subsystem: "delivery_simulator", payload: {})
    super(event_type: "delivery.failure", order_id: order_id, subsystem: subsystem,
          payload: payload.merge(failure_type: "DELIVERY_FAILURE", description: description))
  end
end

class Events::PaymentFailure < DomainEvent
  def initialize(order_id:, description:, subsystem: "payment_simulator", payload: {})
    super(event_type: "payment.failure", order_id: order_id, subsystem: subsystem,
          payload: payload.merge(failure_type: "PAYMENT_FAILURE", description: description))
  end
end

class Events::ExternalServiceFailure < DomainEvent
  def initialize(order_id:, description:, subsystem: "external", payload: {})
    super(event_type: "external.service_failure", order_id: order_id, subsystem: subsystem,
          payload: payload.merge(failure_type: "EXTERNAL_SERVICE_FAILURE", description: description))
  end
end

# Emitted by FailureInjector — carries injected: true in payload (ADR-07)
class Events::FailureInjected < DomainEvent
  def initialize(order_id:, failure_type:, subsystem: "failure_injector", payload: {})
    super(event_type: "failure.injected", order_id: order_id, subsystem: subsystem,
          payload: payload.merge(failure_type: failure_type, injected: true))
  end
end

# ---------------------------------------------------------------------------
# SLA events
# ---------------------------------------------------------------------------

class Events::SlaWarning < DomainEvent
  def initialize(order_id:, phase:, elapsed_seconds:, threshold_seconds:, subsystem: "sla_monitor", payload: {})
    super(event_type: "sla.warning", order_id: order_id, subsystem: subsystem,
          payload: payload.merge(phase: phase, elapsed_seconds: elapsed_seconds,
                                 threshold_seconds: threshold_seconds))
  end
end

class Events::SlaBreached < DomainEvent
  def initialize(order_id:, phase:, elapsed_seconds:, threshold_seconds:, subsystem: "sla_monitor", payload: {})
    super(event_type: "sla.breached", order_id: order_id, subsystem: subsystem,
          payload: payload.merge(phase: phase, elapsed_seconds: elapsed_seconds,
                                 threshold_seconds: threshold_seconds))
  end
end

# ---------------------------------------------------------------------------
# Recovery events
# ---------------------------------------------------------------------------

class Events::RecoveryProposed < DomainEvent
  def initialize(order_id:, proposals:, subsystem: "recovery_orchestrator", payload: {})
    super(event_type: "recovery.proposed", order_id: order_id, subsystem: subsystem,
          payload: payload.merge(proposals: proposals))
  end
end

class Events::RecoveryApproved < DomainEvent
  def initialize(order_id:, action_type:, subsystem: "policy_engine", payload: {})
    super(event_type: "recovery.approved", order_id: order_id, subsystem: subsystem,
          payload: payload.merge(action_type: action_type))
  end
end

class Events::RecoveryRejected < DomainEvent
  def initialize(order_id:, action_type:, reason:, subsystem: "policy_engine", payload: {})
    super(event_type: "recovery.rejected", order_id: order_id, subsystem: subsystem,
          payload: payload.merge(action_type: action_type, reason: reason))
  end
end

class Events::RecoveryExecuted < DomainEvent
  def initialize(order_id:, action_type:, idempotency_key:, subsystem: "action_executor", payload: {})
    super(event_type: "recovery.executed", order_id: order_id, subsystem: subsystem,
          payload: payload.merge(action_type: action_type, idempotency_key: idempotency_key))
  end
end

# ---------------------------------------------------------------------------
# Approval events
# ---------------------------------------------------------------------------

class Events::ApprovalRequested < DomainEvent
  def initialize(order_id:, approval_queue_id:, action_type:, subsystem: "recovery_orchestrator", payload: {})
    super(event_type: "approval.requested", order_id: order_id, subsystem: subsystem,
          payload: payload.merge(approval_queue_id: approval_queue_id, action_type: action_type))
  end
end

class Events::ApprovalReceived < DomainEvent
  def initialize(order_id:, approval_queue_id:, decision:, decided_by:, subsystem: "approval_queue", payload: {})
    super(event_type: "approval.received", order_id: order_id, subsystem: subsystem,
          payload: payload.merge(approval_queue_id: approval_queue_id,
                                 decision: decision, decided_by: decided_by))
  end
end
