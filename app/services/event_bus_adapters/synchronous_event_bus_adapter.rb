# frozen_string_literal: true

# SynchronousEventBusAdapter — delivers events inline in the calling thread.
#
# Used in tests (via SynchronousEventBusAdapter) and can be selected via config.
# Guarantees that by the time EventBus.publish returns, all registered handlers
# have been called (AC-02.6).
#
# AC-02.5: exceptions in one handler are rescued and logged; other handlers
# still receive the event.
#
class SynchronousEventBusAdapter
  def initialize
    @handlers     = Hash.new { |h, k| h[k] = [] }  # event_type => [callable]
    @all_handlers = []                                # called for every event
    @mutex        = Mutex.new
  end

  def publish(event)
    handlers_for = @mutex.synchronize do
      specific = @handlers[event.event_type].dup
      all      = @all_handlers.dup
      specific + all
    end

    handlers_for.each do |handler|
      handler.call(event)
    rescue => e
      # AC-02.5: one failing handler must not prevent others from receiving the event
      Rails.logger.error "[EventBus] Handler #{handler.inspect} raised for " \
                         "#{event.event_type}: #{e.class}: #{e.message}"
    end
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
