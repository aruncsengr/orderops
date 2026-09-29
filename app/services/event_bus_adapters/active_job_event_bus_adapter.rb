# frozen_string_literal: true

# ActiveJobEventBusAdapter — delivers events via ActiveJob (Solid Queue in V1).
#
# Each EventBus.publish call:
#   1. Immediately calls all in-process handlers (e.g. AuditTrail) synchronously
#      in the calling thread. This means audit records are written before
#      #publish returns, but they are NOT in the same database transaction as
#      the triggering state change — they are separate INSERTs. A crash between
#      the order UPDATE committing and the audit INSERT completing will leave a
#      gap. This is an accepted trade-off for V1; the append-only trigger and
#      per-order sequence numbers make such gaps detectable.
#   2. Enqueues DispatchDomainEventJob (via Solid Queue) for any async
#      subscribers that need background processing.
#
# ADR-03: The interface is identical to SynchronousEventBusAdapter so the two
# are interchangeable without changing callers.
#
class ActiveJobEventBusAdapter
  def initialize
    @handlers     = Hash.new { |h, k| h[k] = [] }
    @all_handlers = []
    @mutex        = Mutex.new
  end

  def publish(event)
    # Phase 1: call all registered in-process handlers synchronously
    handlers_for = @mutex.synchronize do
      (@handlers[event.event_type] + @all_handlers).dup
    end

    handlers_for.each do |handler|
      handler.call(event)
    rescue => e
      Rails.logger.error "[EventBus] Handler #{handler.inspect} raised for " \
                         "#{event.event_type}: #{e.class}: #{e.message}"
    end

    # Phase 2: enqueue job for any additional async processing registered later
    # (In V1 this is a no-op beyond the in-process dispatch above, but the
    # hook is here so async-only subscribers can be added in Phase 2+ without
    # changing the adapter interface.)
    DispatchDomainEventJob.perform_later(event.to_h)
  rescue => e
    Rails.logger.error "[EventBus] Failed to enqueue DispatchDomainEventJob " \
                       "for #{event.event_type}: #{e.class}: #{e.message}"
  end

  def subscribe(event_type, handler)
    raise ArgumentError, "Handler must respond to #call" unless handler.respond_to?(:call)

    @mutex.synchronize { @handlers[event_type.to_s] << handler }
  end

  def subscribe_all(handler)
    raise ArgumentError, "Handler must respond to #call" unless handler.respond_to?(:call)

    @mutex.synchronize { @all_handlers << handler }
  end

  def reset_handlers!
    @mutex.synchronize do
      @handlers.clear
      @all_handlers.clear
    end
  end
end
