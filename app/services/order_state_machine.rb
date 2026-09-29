# frozen_string_literal: true

# OrderStateMachine — the single authority for order state transitions (ADR-04).
#
# ALL state changes go through this service. No code sets order.state= directly.
#
# Concurrency: uses Rails optimistic locking (lock_version). A concurrent
# transition on a stale version raises ActiveRecord::StaleObjectError. Callers
# must handle this by reloading and retrying or abandoning.
#
# After a successful transition:
#   - publishes an Events::OrderStateChanged domain event via EventBus
#   - returns the updated order
#
# On failure:
#   - raises InvalidTransitionError (invalid transition attempt)
#   - raises ActiveRecord::StaleObjectError (concurrent modification)
#   - raises ActiveRecord::RecordInvalid (validation failure)
#
class OrderStateMachine
  class InvalidTransitionError < StandardError
    def initialize(order_id, from, to)
      super("Order #{order_id}: transition #{from} → #{to} is not allowed")
    end
  end

  # Transition +order+ to +target_state+.
  #
  # @param order  [Order]  the order to transition (must be a persisted record)
  # @param target [String, Symbol] the target state
  # @param actor  [String] who triggered the transition (for audit)
  # @param metadata [Hash] extra data merged into the event payload
  # @return [Order] the updated order
  #
  def self.transition!(order, target, actor: "system", metadata: {})
    new.transition!(order, target, actor: actor, metadata: metadata)
  end

  def transition!(order, target, actor: "system", metadata: {})
    target = target.to_s
    from   = order.state

    raise InvalidTransitionError.new(order.id, from, target) unless order.transition_allowed_to?(target)

    # Update state atomically. Rails increments lock_version automatically.
    order.update!(state: target, **sla_fields_for(target, order))

    event = Events::OrderStateChanged.new(
      order_id:   order.id,
      from_state: from,
      to_state:   target,
      actor:      actor,
      payload:    metadata
    )

    EventBus.publish(event)

    order
  end

  private

  # Reset SLA phase tracking when entering a new billable phase.
  def sla_fields_for(target_state, order)
    phase = SLA_PHASE_FOR_STATE[target_state]
    return {} unless phase

    { sla_phase: phase, sla_started_at: Time.current, sla_status: "ok" }
  end

  # Map target states to their SLA phase name.
  # Only states that START a new SLA clock are listed here.
  SLA_PHASE_FOR_STATE = {
    "pending"          => "assignment",
    "assigned"         => "acceptance",
    "preparing"        => "preparation",
    "ready_for_pickup" => "pickup",
    "in_delivery"      => "delivery"
  }.freeze
end
