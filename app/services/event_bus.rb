# frozen_string_literal: true

# EventBus — the single interface all subsystems use to publish and subscribe
# to domain events (ADR-03, REQ-02).
#
# The concrete backing adapter is injected at startup via the Rails initializer
# (config/initializers/event_bus.rb). In V1 the ActiveJobEventBusAdapter is
# used in all non-test environments; SynchronousEventBusAdapter is used in tests.
#
# Public interface (ADR-03):
#   EventBus.publish(event)           — deliver a DomainEvent to all registered handlers
#   EventBus.subscribe(type, handler) — register a callable handler for an event type
#   EventBus.subscribe_all(handler)   — register a handler for EVERY event type
#   EventBus.reset_handlers!          — for test use only; clears all subscriptions
#
module EventBus
  class << self
    def adapter
      @adapter || raise(RuntimeError, "EventBus adapter not configured. " \
        "Call EventBus.adapter = <adapter> in an initializer.")
    end

    def adapter=(adapter_instance)
      @adapter = adapter_instance
    end

    # Publish a DomainEvent. Raises ArgumentError if event is not a DomainEvent.
    def publish(event)
      raise ArgumentError, "Expected a DomainEvent, got #{event.class}" unless event.is_a?(DomainEvent)

      adapter.publish(event)
    end

    # Subscribe a handler (callable) to a specific event type string.
    # handler must respond to #call(event).
    def subscribe(event_type, handler)
      adapter.subscribe(event_type.to_s, handler)
    end

    # Subscribe a handler to ALL event types.
    def subscribe_all(handler)
      adapter.subscribe_all(handler)
    end

    # Clear all subscriptions. For use in tests only.
    def reset_handlers!
      adapter.reset_handlers!
    end
  end
end
