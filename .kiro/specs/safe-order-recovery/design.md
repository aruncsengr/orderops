# Design Document: Safe Order Recovery

## Overview

Safe Order Recovery is the core reliability feature of the OrderOps platform. It implements a structured, auditable pipeline that detects order failures, diagnoses the cause through an AI agent, validates recovery options through a deterministic policy engine, obtains human approval when required, and executes the approved action — all within a Ruby on Rails 8.1 application.

The guiding constraint that shapes every architectural choice:

> **AI reasons and recommends. PolicyEngine decides. A human approves when required. ActionExecutor acts only on approved decisions.**

The design targets a compelling 5-minute live demo running two scenarios end-to-end:
- **Scenario 1** — Automatic restaurant reroute (no human intervention required)
- **Scenario 2** — Full refund requiring human dashboard approval

---

## Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Rails 8.1 Application                           │
│                                                                           │
│  HTTP/Turbo ──► DashboardController ──► Views (Turbo Frames/Streams)   │
│                        │                                                  │
│               ApprovalRequestsController                                  │
│                        │                                                  │
│  ┌─────────────────────┼──────────────────────────────────────────────┐  │
│  │                  Domain Layer                                        │  │
│  │                                                                      │  │
│  │  ┌──────────────┐   ┌──────────────┐   ┌──────────────────────┐   │  │
│  │  │    Order     │   │ FailureEvent │   │   RecoveryAction     │   │  │
│  │  │  (AASM state │   │  (enum type, │   │  (proposed/approved/ │   │  │
│  │  │   machine)   │   │   injected?) │   │   executed/failed)   │   │  │
│  │  └──────┬───────┘   └──────┬───────┘   └──────────────────────┘   │  │
│  │         │                  │                                         │  │
│  │  ┌──────▼───────┐  ┌───────▼────────┐  ┌──────────────────────┐   │  │
│  │  │  AuditEvent  │  │ ApprovalRequest│  │    PolicyConfig       │   │  │
│  │  │ (append-only)│  │ (pending/appr/ │  │  (YAML, versioned)    │   │  │
│  │  └──────────────┘  │  rejected)     │  └──────────────────────┘   │  │
│  │                     └────────────────┘                              │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                      Service Layer                                    │  │
│  │                                                                       │  │
│  │  FailureInjector ──► [enqueue] ──► RecoveryOrchestrator (SolidQueue)│  │
│  │                                           │                           │  │
│  │                                    RecoveryAgent                      │  │
│  │                                    (read-only context)                │  │
│  │                                           │ proposal                  │  │
│  │                                    PolicyEngine                       │  │
│  │                                    (pure function)                    │  │
│  │                                           │ decision                  │  │
│  │                              ┌────────────┴────────────┐             │  │
│  │                              │                          │             │  │
│  │                     auto-approve path          requires_human: true   │  │
│  │                              │                          │             │  │
│  │                       ActionExecutor           ApprovalRequest        │  │
│  │                              │                 (PENDING_APPROVAL)     │  │
│  │                    ┌─────────┴──────────┐      operator decides       │  │
│  │                    │                    │             │               │  │
│  │              RestaurantSim        PaymentSim   ResumptionJob          │  │
│  │              VoucherSim           DeliverySim  (re-enqueued)          │  │
│  │              CancellationSim      NotifSim           │               │  │
│  │                                               ActionExecutor          │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │          Solid Cable WebSocket + Turbo Streams                        │  │
│  │  Channel: OrdersChannel (global) + OrderChannel:order_ID (per-order)│  │
│  └─────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Responsibility |
|---|---|
| `Order` / `OrderStateMachine` | Authoritative order lifecycle state; AASM transitions with row lock |
| `FailureEvent` | Records a failure condition (natural or injected) |
| `RecoveryAction` | One proposed or executed recovery action on an order |
| `ApprovalRequest` | Links a high-risk RecoveryAction to an operator decision |
| `AuditEvent` | Append-only immutable record of every meaningful system event |
| `PolicyConfig` | YAML-loaded, versioned configuration for all thresholds and rules |
| `FailureInjector` | Creates FailureEvents, validates terminal state, enqueues orchestrator |
| `RecoveryOrchestrator` | Solid Queue job; coordinates the full pipeline |
| `RecoveryAgent` | AI interface; accepts read-only context, returns ranked proposals |
| `RecoveryContext` | Read-only value object passed to RecoveryAgent; raises on any write attempt |
| `FakeProvider` | Deterministic stub LLM keyed by failure_type; used in tests and demo |
| `PolicyEngine` | Pure function; evaluates guardrails and policy; returns PolicyDecision |
| `ActionExecutor` | Dispatches approved actions to simulators; verifies policy approval in AuditEvents |
| `AuditLogger` | Single-responsibility service for appending AuditEvent records |
| Simulators | In-process stubs for restaurant, payment, delivery, voucher, notification |
| `DashboardController` | Renders dashboard panels; no domain logic |
| `ApprovalRequestsController` | Approve/reject actions; enqueues ResumptionJob |
| Turbo Streams | Real-time partial-page updates broadcast from model callbacks and services |

---

### Data Flow: Demo Scenario 1 — Automatic Restaurant Reroute

```
1. Operator calls FailureInjector.inject(order_id, :kitchen_failure, "...")
   └─► FailureEvent created (injected: true)
   └─► AuditLogger.record(:failure_detected, injected: true)
   └─► RecoveryOrchestrator job enqueued

2. RecoveryOrchestrator#perform
   └─► AuditLogger.record(:recovery_started)
   └─► Broadcast: recovery_queue panel (stage: diagnosing)

3. RecoveryAgent.diagnose(context)
   └─► FakeProvider returns [{action: REROUTE_RESTAURANT, confidence: 0.85, ...}]
   └─► Schema validated
   └─► AuditLogger.record(:ai_diagnosis, model: "fake", output: proposals)
   └─► Broadcast: recovery_queue panel (stage: diagnosed)

4. PolicyEngine.evaluate(input)
   └─► G1-G6 guardrails pass
   └─► Policy config: reroute_count=0 < max(3), confidence=0.85 > threshold(0.5)
   └─► Returns PolicyDecision(APPROVED, requires_human_approval: false)
   └─► AuditLogger.record(:policy_evaluation, status: APPROVED)
   └─► Broadcast: recovery_queue panel (stage: approved)

5. ActionExecutor.execute(recovery_action)  [no ApprovalRequest created]
   └─► Verifies policy AuditEvent exists (raises PolicyBypassError if not)
   └─► RestaurantSimulator.available_restaurants(cuisine_type: "italian")
   └─► Assigns new restaurant to Order
   └─► Order.transition_to!(:recovered)
   └─► RecoveryAction.update!(status: :executed, executed_at: Time.current)
   └─► AuditLogger.record(:action_executed)
   └─► Broadcast: order_stream panel, recovery_queue panel (stage: complete)

6. RecoveryOrchestrator records completion
   └─► AuditLogger.record(:recovery_completed)
   └─► Broadcast: recovery_queue panel (stage: complete)
```

### Data Flow: Demo Scenario 2 — Human Approval for Full Refund

```
1-3. Same as Scenario 1 but FakeProvider returns FULL_REFUND at confidence: 0.90

4. PolicyEngine.evaluate(input)
   └─► Guardrails pass
   └─► total_cents: 7500 > human_approval_refund_threshold_cents: 5000
   └─► Returns PolicyDecision(APPROVED, requires_human_approval: true)
   └─► AuditLogger.record(:policy_evaluation, status: APPROVED, requires_human: true)

5. RecoveryOrchestrator routes to approval path
   └─► ApprovalRequest.create!(status: :pending, recovery_action: action)
   └─► Order.transition_to!(:pending_approval)
   └─► AuditLogger.record(:approval_requested)
   └─► Broadcast: approval_queue panel (new pending item with elapsed timer)
   └─► JOB HALTS (no further steps)

6. Operator clicks Approve on dashboard
   └─► POST /approval_requests/:id/approve
   └─► ApprovalRequestsController#approve
   └─► ApprovalRequest.update!(status: :approved, operator_id: ..., decided_at: ...)
   └─► AuditLogger.record(:human_approval_received)
   └─► ResumptionJob.perform_later(approval_request_id: ...)
   └─► Turbo Stream: inline success confirmation, approval_queue panel updates

7. ResumptionJob#perform
   └─► Loads ApprovalRequest (status: approved)
   └─► ActionExecutor.execute(recovery_action)
       └─► Verifies approved ApprovalRequest exists (raises PolicyBypassError if not)
       └─► PaymentSimulator.refund(amount_cents: 7500)
       └─► Order.transition_to!(:recovered)
       └─► RecoveryAction.update!(status: :executed)
       └─► AuditLogger.record(:action_executed)
   └─► AuditLogger.record(:recovery_completed)
   └─► Broadcast: order_stream, recovery_queue (complete)
```

---

## Data Models

### `orders` table

```ruby
# app/models/order.rb
create_table :orders do |t|
  t.string   :external_id,       null: false, index: { unique: true }
  t.bigint   :customer_id,       null: false, index: true
  t.bigint   :restaurant_id,     index: true           # nullable until assigned
  t.string   :cuisine_type,      null: false
  t.integer  :total_cents,       null: false, default: 0
  t.jsonb    :items,             null: false, default: []
  t.jsonb    :delivery_address,  null: false, default: {}
  t.string   :state,             null: false, default: 'pending', index: true
  t.timestamps
end

add_index :orders, :state
```

**Validations:** `external_id`, `customer_id`, `cuisine_type`, `total_cents >= 0`, `state` in allowed set.

**Relationships:**
- `has_many :failure_events`
- `has_many :recovery_actions`
- `has_many :approval_requests`
- `has_many :audit_events`

**AASM:** State machine defined in `OrderStateMachine` concern, included in `Order`. The `state` column is a plain string (not a PostgreSQL enum) to allow AASM to manage all transition logic in Ruby.

---

### `failure_events` table

```ruby
create_table :failure_events do |t|
  t.bigint   :order_id,     null: false, index: true
  t.string   :failure_type, null: false   # enum validated at app layer
  t.text     :description,  null: false
  t.boolean  :injected,     null: false, default: false
  t.datetime :occurred_at,  null: false, precision: 6
  t.timestamps
end

add_index :failure_events, [:order_id, :occurred_at]
```

**`failure_type` values:** `restaurant_rejection`, `restaurant_unavailable`, `inventory_failure`, `kitchen_delay`, `kitchen_failure`, `delivery_delay`, `delivery_failure`, `payment_failure`, `external_service_failure`.

Defined as a Ruby `enum` on the model (stored as string for readability in the audit trail).

**Validations:** `order_id`, `failure_type` in enum, `injected` not nil, `occurred_at` present.

**Relationships:** `belongs_to :order`, `has_one :recovery_action`.

---

### `recovery_actions` table

```ruby
create_table :recovery_actions do |t|
  t.bigint   :order_id,                  null: false, index: true
  t.bigint   :failure_event_id,          null: false, index: true
  t.string   :action_type,               null: false   # enum
  t.string   :status,                    null: false, default: 'proposed', index: true
  t.decimal  :ai_confidence,             precision: 4, scale: 3  # 0.000–1.000
  t.text     :ai_reasoning
  t.string   :estimated_customer_impact  # low / medium / high
  t.jsonb    :parameters,                null: false, default: {}
  t.datetime :executed_at,               precision: 6
  t.timestamps
end

add_index :recovery_actions, [:order_id, :status]
add_index :recovery_actions, [:order_id, :action_type]
```

**`action_type` values:** `reroute_restaurant`, `partial_refund`, `full_refund`, `issue_voucher`, `escalate_to_human`, `cancel_order`, `retry_delivery`, `contact_customer`.

**`status` values:** `proposed`, `approved`, `rejected`, `executing`, `executed`, `failed`.

**Relationships:** `belongs_to :order`, `belongs_to :failure_event`, `has_one :approval_request`.

---

### `approval_requests` table

```ruby
create_table :approval_requests do |t|
  t.bigint   :order_id,           null: false, index: true
  t.bigint   :recovery_action_id, null: false, index: { unique: true }
  t.string   :status,             null: false, default: 'pending', index: true
  t.string   :operator_id
  t.text     :operator_note
  t.datetime :requested_at,       null: false, precision: 6
  t.datetime :decided_at,         precision: 6
  t.timestamps
end

# Ensures at most one pending ApprovalRequest per Order at any time.
# Uses a partial unique index — only one row with status='pending' per order_id.
add_index :approval_requests, :order_id,
          unique: true,
          where: "status = 'pending'",
          name: 'idx_approval_requests_one_pending_per_order'
```

**Validations:** `order_id`, `recovery_action_id`, `requested_at`, `status` in enum. `decided_at` required when status is `approved` or `rejected`.

**Relationships:** `belongs_to :order`, `belongs_to :recovery_action`.

---

### `audit_events` table

```ruby
create_table :audit_events do |t|
  t.bigint   :order_id,      null: false, index: true
  t.string   :event_type,    null: false, index: true
  t.string   :actor_type,    null: false   # system / ai / human / simulator
  t.string   :actor_id
  t.string   :from_state
  t.string   :to_state
  t.jsonb    :payload,       null: false, default: {}
  t.string   :policy_version
  t.string   :ai_model
  t.boolean  :injected,      null: false, default: false
  t.datetime :occurred_at,   null: false, precision: 6, index: true
  # No updated_at — append-only; no update/delete migrations ever created
end

add_index :audit_events, [:order_id, :occurred_at]
```

**`event_type` values (exhaustive set):**
`order_state_changed`, `failure_detected`, `recovery_started`, `ai_diagnosis`, `ai_fallback`, `ai_error`, `ai_validation_error`, `policy_evaluation`, `approval_requested`, `human_approval_received`, `human_approval_rejected`, `approval_timeout`, `approval_timeout_expired`, `action_executed`, `execution_error`, `policy_error`, `recovery_completed`, `recovery_failed`, `orchestration_exhausted`, `escalated_to_human`.

**Append-only enforcement:** No `update` or `delete` migrations will ever be written for `audit_events`. The `AuditLogger` service is the only write path. Direct `AuditEvent.update` or `.destroy` calls will raise `FrozenRecord::Error` via a model `before_update` / `before_destroy` callback that always raises.

**Relationships:** `belongs_to :order`.

---

## Order State Machine

### Transition Diagram

```
                   ┌──────────┐
         ┌────────►│ PENDING  │◄──────────────────┐
         │         └────┬─────┘                   │
         │  ASSIGNED    │                          │ REROUTE (ASSIGNED→PENDING)
         │  →PENDING    ▼                          │
         │         ┌──────────┐                    │
         │    ┌───►│ ASSIGNED │────────────────────┘
         │    │    └────┬─────┘
         │    │         │ accepted
         │    │         ▼
         │    │    ┌──────────┐
         │    │    │ ACCEPTED │
         │    │    └────┬─────┘
         │    │         │ preparing
         │    │         ▼
         │    │    ┌──────────────┐
         │    │    │  PREPARING   │
         │    │    └────┬─────────┘
         │    │         │ ready
         │    │         ▼
         │    │    ┌─────────────────┐
         │    │    │ READY_FOR_PICKUP│
         │    │    └────┬────────────┘
         │    │         │ picked_up
         │    │         ▼
         │    │    ┌─────────────┐
         │    │    │ IN_DELIVERY │
         │    │    └────┬────────┘
         │    │         │ delivered
         │    │         ▼
         │    │    ┌───────────┐
         │    │    │ DELIVERED │ ◄── TERMINAL
         │    │    └───────────┘
         │    │
         │ All non-terminal states can fail:
         │    │         ▼
         │    │    ┌────────┐
         │    │    │ FAILED │──────────┐
         │    │    └───┬────┘          │
         │    │        │               │
         │    │   pending_approval   recovered / cancelled
         │    │        │
         │    │        ▼
         │    │   ┌────────────────┐
         │    │   │PENDING_APPROVAL│──► CANCELLED (terminal)
         │    │   └───────┬────────┘
         │    │           │ recovering
         │    │           ▼
         │    │   ┌───────────┐
         │    └───│ RECOVERING│
         │        └─────┬─────┘
         │              │ recovered
         │              ▼
         │        ┌──────────┐
         └────────│ RECOVERED│ ◄── TERMINAL
                  └──────────┘

CANCELLED ◄── TERMINAL (from PENDING, FAILED, PENDING_APPROVAL)
```

### Implementation (AASM)

AASM is chosen over `state_machines-activerecord` because:
- It has first-class Rails integration with ActiveRecord callbacks
- `aasm_state` column maps cleanly to a plain string column
- `guard` blocks, `before`, `after`, and `error` callbacks are composable with service calls
- Broader community adoption means better long-term maintenance

```ruby
# app/models/concerns/order_state_machine.rb
module OrderStateMachine
  extend ActiveSupport::Concern

  included do
    include AASM

    aasm column: :state, whiny_transitions: true do
      state :pending, initial: true
      state :assigned, :accepted, :preparing
      state :ready_for_pickup, :in_delivery, :delivered
      state :failed, :cancelled, :recovered
      state :pending_approval, :recovering

      # Forward path
      event :assign      do transitions from: :pending,           to: :assigned      end
      event :accept      do transitions from: :assigned,          to: :accepted      end
      event :begin_prep  do transitions from: :accepted,          to: :preparing     end
      event :ready       do transitions from: :preparing,         to: :ready_for_pickup end
      event :pick_up     do transitions from: :ready_for_pickup,  to: :in_delivery   end
      event :deliver     do transitions from: :in_delivery,       to: :delivered     end

      # Re-route (back to pending for new restaurant assignment)
      event :reroute     do transitions from: :assigned,          to: :pending       end

      # Failure paths
      event :fail do
        transitions from: [:assigned, :accepted, :preparing,
                            :ready_for_pickup, :in_delivery],     to: :failed
      end

      # Recovery paths
      event :request_approval do transitions from: :failed,        to: :pending_approval end
      event :begin_recovery   do transitions from: :pending_approval, to: :recovering   end
      event :recover          do transitions from: [:recovering, :failed], to: :recovered end

      # Cancellation
      event :cancel do
        transitions from: [:pending, :assigned, :accepted, :failed, :pending_approval], to: :cancelled
      end

      # Callbacks — fire for every transition
      before_all_transitions :acquire_row_lock
      after_all_transitions  :record_state_change_audit_event
    end
  end

  private

  def acquire_row_lock
    # with_lock acquires a PostgreSQL row-level lock for the duration of the
    # transaction, serialising concurrent transition attempts on the same Order.
    lock!
  end

  def record_state_change_audit_event
    AuditLogger.record(
      order:      self,
      event_type: :order_state_changed,
      actor_type: :system,
      from_state: aasm.from_state,
      to_state:   aasm.to_state
    )
  end
end
```

### Concurrency Strategy

`Order#lock!` (PostgreSQL `SELECT ... FOR UPDATE`) inside a database transaction is the concurrency mechanism. All AASM transition calls must be wrapped in `Order.transaction { order.event! }`. The `acquire_row_lock` before-callback ensures the lock is held for the full transition + audit event write.

For V1 with Solid Queue (single-process by default), this is sufficient. Multi-process deployments benefit from the same mechanism because the lock is at the database level.

### Terminal State Enforcement

AASM's `whiny_transitions: true` raises `AASM::InvalidTransition` for any attempted transition not in the transition table, including attempts from terminal states. The `DELIVERED`, `CANCELLED`, and `RECOVERED` states have no outbound events. `FAILED` has three (request_approval, recover, cancel) per the spec.

---

## Components and Interfaces

### `FailureInjector`

**File:** `app/services/failure_injector.rb`

**Responsibility:** Create `FailureEvent` records through the same pipeline as natural failures. Validate that the target order is not in a terminal state. Enqueue `RecoveryOrchestrator`.

**Interface:**
```ruby
FailureInjector.inject(
  order_id:     Integer,
  failure_type: Symbol,   # one of 9 enum values
  description:  String
) → FailureEvent          # raises TerminalOrderError if order is terminal
```

**Reads:** `Order.find(order_id)` — checks `state`.

**Writes:** `FailureEvent.create!`, `AuditLogger.record(:failure_detected)`, `RecoveryOrchestrator.perform_later`.

**Error handling:** Raises `FailureInjector::TerminalOrderError` if order is in a terminal state. Raises `ActiveRecord::RecordInvalid` on validation failure.

---

### `RecoveryOrchestrator` (Solid Queue Job)

**File:** `app/jobs/recovery_orchestrator_job.rb`

**Responsibility:** Coordinate the full recovery pipeline from FailureEvent through ActionExecutor. Acts as the pipeline glue — delegates to specialist services at each step.

**Interface:**
```ruby
RecoveryOrchestratorJob.perform_later(failure_event_id: Integer)
RecoveryOrchestratorJob.perform_later(approval_request_id: Integer)  # resumption path
```

**Pipeline:**
1. Load `FailureEvent` (or `ApprovalRequest` for resumption)
2. `AuditLogger.record(:recovery_started)`
3. `context = RecoveryContext.build(order, failure_event)`
4. `proposals = RecoveryAgent.diagnose(context)` — with rescue → fallback
5. `AuditLogger.record(:ai_diagnosis, ...)`
6. For each proposal (highest confidence first):
   a. `decision = PolicyEngine.evaluate(PolicyInput.new(...))`
   b. `AuditLogger.record(:policy_evaluation, ...)`
   c. If `DENIED`: try next proposal; if none left → escalate
   d. If `APPROVED, requires_human_approval: false`: call `ActionExecutor`, record, done
   e. If `APPROVED, requires_human_approval: true`: create `ApprovalRequest`, transition order to `PENDING_APPROVAL`, broadcast, halt
7. On `ActionExecutor` error: rescue, transition to `FAILED`, record `recovery_failed`
8. On job retry exhaustion: record `orchestration_exhausted`

**Reads:** `FailureEvent`, `Order`, `AuditEvent` history, `PolicyConfig`.

**Writes:** `RecoveryAction`, `ApprovalRequest` (conditionally), transitions `Order` state, `AuditEvent` via `AuditLogger`.

**Error handling:** All exceptions from `RecoveryAgent` are rescued (records `ai_error`, applies fallback). All exceptions from `PolicyEngine` are rescued (records `policy_error`, transitions order to `FAILED`). All exceptions from `ActionExecutor` are rescued (records `execution_error`, transitions order to `FAILED`).

---

### `RecoveryAgent`

**File:** `app/services/recovery_agent.rb`

**Responsibility:** Call the configured LLM provider with a structured prompt and read-only context; validate the response schema; return ranked proposals. Apply deterministic fallback on provider failure.

**Interface:**
```ruby
RecoveryAgent.diagnose(context: RecoveryContext) → Array<Proposal>
# Proposal: Struct with action_type, confidence, reasoning, estimated_customer_impact
```

**Reads:** `RecoveryContext` (read-only value object), `PolicyConfig` (permitted action types).

**Writes:** Nothing directly. Returns proposals. Caller records the AuditEvent.

**Provider selection:** `Rails.application.config.recovery_agent_provider` (set in `config/application.rb` or overridden per environment). Default is `FakeProvider` in test and development.

**Fallback table:**

| failure_type | fallback_action |
|---|---|
| `kitchen_failure` | `reroute_restaurant` |
| `kitchen_delay` | `reroute_restaurant` |
| `restaurant_rejection` | `reroute_restaurant` |
| `restaurant_unavailable` | `reroute_restaurant` |
| `inventory_failure` | `reroute_restaurant` |
| `delivery_failure` | `retry_delivery` |
| `delivery_delay` | `retry_delivery` |
| `payment_failure` | `escalate_to_human` |
| `external_service_failure` | `escalate_to_human` |

Fallback produces a single `Proposal` with `confidence: 0.0` and `reasoning: "deterministic_fallback"`.

**Error handling:** Rescues `Timeout::Error`, `StandardError` from provider call. Applies fallback. Caller is responsible for recording `ai_error` or `ai_fallback` audit events.

---

### `RecoveryContext`

**File:** `app/services/recovery_context.rb`

**Responsibility:** Read-only value object passed to `RecoveryAgent`. Exposes order data and history through read-only accessors. Raises `NotImplementedError` on any write attempt.

**Exposed (read-only):**
- `order_state`, `order_id`, `cuisine_type`, `total_cents`
- `failure_type`, `failure_description`
- `audit_history` — array of `{event_type, occurred_at, payload}` hashes
- `permitted_action_types` — pre-filtered list from `PolicyConfig`
- `available_restaurants` — from `RestaurantSimulator.available_for(cuisine_type:)`

**Blocked (raises `NotImplementedError`):** Any method matching the prohibited categories from REQ-11 AC1a — all `ActiveRecord` write methods, state transition methods, refund/cancel/reroute methods, `ActionExecutor` references.

Implementation uses `method_missing` to intercept undefined methods and raise `NotImplementedError` with a message identifying the prohibited category.

---

### `PolicyEngine`

**File:** `app/services/policy_engine.rb`

**Responsibility:** Pure function evaluation of guardrail rules and policy configuration. No I/O. Returns a `PolicyDecision` value object.

**Interface:**
```ruby
PolicyEngine.evaluate(input: PolicyInput) → PolicyDecision
```

`PolicyInput` fields: `action_type`, `order_snapshot` (plain hash), `audit_history` (array of hashes), `policy_config` (loaded `PolicyConfig` value object), `ai_confidence` (Float).

`PolicyDecision` fields: `status` (`:approved` / `:denied`), `requires_human_approval` (Boolean), `reason` (String), `guardrail_violated` (Symbol, nil if approved).

**Evaluation order:**
1. G1: refund_amount ≤ order.total_cents
2. G2: FULL_REFUND + no partial_delivery_confirmed AuditEvent
3. G3: reroute_count < policy_config.max_reroute_attempts
4. G4: order not in terminal state
5. G5: CANCEL_ORDER requires approved ApprovalRequest OR explicit policy permission
6. G6: no existing refund_executed AuditEvent for this order
7. Configurable policy checks (refund eligibility by failure type, etc.)
8. Human approval triggers (5 conditions from REQ-04 AC5)

**Pure function guarantee:** `PolicyEngine` is a module with a single `self.evaluate` class method. It holds no instance state. All required data arrives via `PolicyInput`. No database calls, no file reads, no HTTP during evaluation.

---

### `ActionExecutor`

**File:** `app/services/action_executor.rb`

**Responsibility:** Execute a single approved `RecoveryAction` by delegating to the correct simulator. Verify that a `PolicyEngine` approval AuditEvent exists before any execution.

**Interface:**
```ruby
ActionExecutor.execute(recovery_action: RecoveryAction, orchestrator_run_id: String) → Result
```

**Authorization check** (runs before any dispatch):
```ruby
audit_events = AuditEvent.where(
  order_id: recovery_action.order_id,
  event_type: 'policy_evaluation',
  "payload->>'status'": 'APPROVED'
).where("occurred_at > ?", orchestrator_run_id_started_at)

raise PolicyBypassError unless audit_events.exists?
```

**Dispatch table:**
- `reroute_restaurant` → `RestaurantSimulator`
- `full_refund`, `partial_refund` → `PaymentSimulator`
- `issue_voucher` → `VoucherSimulator`
- `cancel_order` → `CancellationSimulator`
- `retry_delivery` → `DeliverySimulator`
- `contact_customer` → `NotificationSimulator`
- `escalate_to_human` → creates `ApprovalRequest`, no simulator call

**Writes:** `RecoveryAction#update!(status: :executed, executed_at: ...)` on success; `RecoveryAction#update!(status: :failed)` on error.

**Error handling:** Re-raises simulator errors to `RecoveryOrchestrator`.

---

### `AuditLogger`

**File:** `app/services/audit_logger.rb`

**Responsibility:** The single write path for `AuditEvent` records. Enforces append-only semantics.

**Interface:**
```ruby
AuditLogger.record(
  order:        Order,
  event_type:   Symbol,
  actor_type:   Symbol,    # :system, :ai, :human, :simulator
  actor_id:     String,    # optional
  from_state:   String,    # optional
  to_state:     String,    # optional
  payload:      Hash,      # optional, default {}
  policy_version: String,  # optional
  ai_model:     String,    # optional
  injected:     Boolean    # optional, default false
) → AuditEvent
```

Broadcasts a Turbo Stream update to the audit timeline for the order's channel after every record creation.

---

## AI Provider Boundary

### `FakeProvider`

**File:** `app/services/providers/fake_provider.rb`

Keyed by `failure_type`. Returns a deterministic ranked array of `Proposal` structs. Used in test and development environments.

```ruby
RESPONSES = {
  kitchen_failure: [
    Proposal.new(action_type: :reroute_restaurant, confidence: 0.85,
                 reasoning: "Kitchen failure — reroute to available restaurant",
                 estimated_customer_impact: :medium),
    Proposal.new(action_type: :cancel_order, confidence: 0.40,
                 reasoning: "Cancel if no restaurant available",
                 estimated_customer_impact: :high)
  ],
  delivery_failure: [
    Proposal.new(action_type: :full_refund, confidence: 0.90,
                 reasoning: "Delivery failure — full refund appropriate",
                 estimated_customer_impact: :high),
    Proposal.new(action_type: :retry_delivery, confidence: 0.55,
                 reasoning: "Retry delivery if courier available",
                 estimated_customer_impact: :medium)
  ],
  # ... all 9 failure types
}.freeze
```

### Real Provider Interface

Real providers (e.g., Amazon Bedrock, OpenAI) conform to the same interface:

```ruby
module Providers
  class BedrockProvider
    def diagnose(context:, permitted_actions:, timeout_seconds:) → Array<Proposal>
  end
end
```

The provider receives a structured prompt built from `RecoveryContext` and the list of permitted action types. The response must match this JSON schema:

```json
{
  "type": "array",
  "items": {
    "type": "object",
    "required": ["action_type", "confidence", "reasoning", "estimated_customer_impact"],
    "properties": {
      "action_type": { "type": "string", "enum": ["reroute_restaurant", "partial_refund", ...] },
      "confidence": { "type": "number", "minimum": 0.0, "maximum": 1.0 },
      "reasoning": { "type": "string" },
      "estimated_customer_impact": { "type": "string", "enum": ["low", "medium", "high"] }
    }
  }
}
```

Schema validation uses `json-schema` gem. Validation failure triggers the fallback strategy.

### Provider Configuration

```ruby
# config/application.rb
config.recovery_agent_provider = ENV.fetch("RECOVERY_AGENT_PROVIDER", "fake")

# config/initializers/recovery_agent.rb
RecoveryAgent.provider = case Rails.application.config.recovery_agent_provider
when "fake"    then Providers::FakeProvider.new
when "bedrock" then Providers::BedrockProvider.new(model: ENV["BEDROCK_MODEL"])
when "openai"  then Providers::OpenAIProvider.new(model: ENV["OPENAI_MODEL"])
end
```

---

## PolicyEngine Design

### PolicyConfig YAML

```yaml
# config/policy_config.yml
version: "1.0.0"

# Guardrail thresholds
max_reroute_attempts: 3

# Human approval triggers
human_approval_refund_threshold_cents: 5000   # $50
human_approval_reroute_threshold: 2
human_approval_confidence_threshold: 0.5
approval_timeout_seconds: 120

# Per-action configuration
actions:
  reroute_restaurant:
    requires_approval: false
    eligible_failure_types:
      - kitchen_failure
      - kitchen_delay
      - restaurant_rejection
      - restaurant_unavailable
      - inventory_failure
  full_refund:
    requires_approval: false     # overridden by threshold check
    eligible_failure_types:
      - delivery_failure
      - payment_failure
      - kitchen_failure
  partial_refund:
    requires_approval: false
    eligible_failure_types: all
  issue_voucher:
    requires_approval: false
    eligible_failure_types: all
  cancel_order:
    requires_approval: true       # always requires human approval
    eligible_failure_types:
      - payment_failure
  retry_delivery:
    requires_approval: false
    eligible_failure_types:
      - delivery_failure
      - delivery_delay
  escalate_to_human:
    requires_approval: false      # escalation itself needs no approval
    eligible_failure_types: all
  contact_customer:
    requires_approval: false
    eligible_failure_types: all

# SLA budgets (seconds)
sla_budgets:
  assignment_warning: 60
  assignment_breach: 120
  acceptance_warning: 90
  acceptance_breach: 180
  preparation_warning: 600
  preparation_breach: 900
  pickup_warning: 120
  pickup_breach: 240
  delivery_warning: 1800
  delivery_breach: 2700
  end_to_end_warning: 2700
  end_to_end_breach: 3600
```

**Loading:** `PolicyConfig.load!` is called once in `config/initializers/policy_config.rb`. Raises `PolicyConfig::MissingConfigError` if the file is missing or `PolicyConfig::InvalidConfigError` if required keys are absent.

### PolicyInput / PolicyDecision

```ruby
PolicyInput = Data.define(
  :action_type,        # Symbol
  :order_snapshot,     # Hash with :state, :total_cents, :id
  :audit_history,      # Array<Hash> of AuditEvent-like hashes
  :policy_config,      # PolicyConfig value object
  :ai_confidence       # Float, 0.0–1.0
)

PolicyDecision = Data.define(
  :status,                  # :approved | :denied
  :requires_human_approval, # Boolean
  :reason,                  # String
  :guardrail_violated       # Symbol | nil
)
```

### Pure Function Guarantee

`PolicyEngine` is a module (not a class) with a single `self.evaluate` method. It has no `@@class_variables`, no `@instance_variables`, and no side effects. All data flows in via `PolicyInput` and out via `PolicyDecision`. Ruby's `Module.freeze` is applied after definition to prevent monkey-patching in test runs.

---

## Human Approval Flow

### State Transition

When `PolicyEngine` returns `requires_human_approval: true`:

1. `RecoveryOrchestrator` creates `RecoveryAction` (status: `approved`)
2. Creates `ApprovalRequest` (status: `pending`, `requested_at: Time.current`)
3. Transitions `Order` to `pending_approval`
4. `AuditLogger.record(:approval_requested)`
5. Broadcasts Turbo Stream update to approval queue panel
6. **Job returns** — the pipeline is complete for now

The partial unique index (`idx_approval_requests_one_pending_per_order`) ensures that creating a second pending `ApprovalRequest` for the same order raises `ActiveRecord::RecordNotUnique`, which `RecoveryOrchestrator` rescues and treats as a no-op (the first request is already pending).

### Resumption via `ResumptionJob`

```ruby
# app/controllers/approval_requests_controller.rb
def approve
  @approval_request = ApprovalRequest.find(params[:id])
  @approval_request.update!(
    status: :approved,
    operator_id: current_operator_id,
    decided_at: Time.current
  )
  AuditLogger.record(order: @approval_request.order,
                     event_type: :human_approval_received,
                     actor_type: :human, actor_id: current_operator_id)
  ResumptionJob.perform_later(approval_request_id: @approval_request.id)
  render turbo_stream: [
    turbo_stream.replace("approval_request_#{@approval_request.id}",
                          partial: "approval_requests/approved")
  ]
end
```

`ResumptionJob` loads the `ApprovalRequest`, confirms `status: :approved`, then calls `ActionExecutor` directly (this is the resumption path, not a full re-run of the orchestrator). This avoids re-running the AI and policy steps that already completed.

### Approval Timeout

`ApprovalTimeoutJob` is scheduled by `RecoveryOrchestrator` when it creates an `ApprovalRequest`:

```ruby
ApprovalTimeoutJob.set(wait: policy_config.approval_timeout_seconds.seconds)
                  .perform_later(approval_request_id: approval_request.id)
```

`ApprovalTimeoutJob` checks if the `ApprovalRequest` is still pending. If so, records an `approval_timeout` `AuditEvent` and broadcasts an escalation update to the approval queue panel. The order remains in `PENDING_APPROVAL` for continued operator visibility.

---

## Simulators Design

All simulators are plain Ruby objects instantiated once and stored in `Rails.application.config.simulators`. They are injected into services via constructor argument (defaulting to the global instances).

### `RestaurantSimulator`

**File:** `app/simulators/restaurant_simulator.rb`

```ruby
class RestaurantSimulator
  Restaurant = Data.define(:id, :name, :cuisine_types, :acceptance_rate, :latency_ms, :available)

  def available_for(cuisine_type:, excluding_restaurant_ids: []) → Array<Restaurant>
  def mark_unavailable(restaurant_id:) → void
  def simulate_acceptance(restaurant_id:) → Boolean  # probabilistic per acceptance_rate
  def seed_restaurants(count:) → void
end
```

Rejection tracking: `ActionExecutor` records `restaurant_rejected` events in `AuditEvent`. `RestaurantSimulator#available_for` accepts `excluding_restaurant_ids` — the caller (ActionExecutor) queries `AuditEvent` for prior rejections and passes them in.

### `PaymentSimulator`

**File:** `app/simulators/payment_simulator.rb`

```ruby
class PaymentSimulator
  def refund(amount_cents:, order_id:) → { transaction_reference: String }
  # Raises PaymentSimulator::PaymentError on configurable failure rate
end
```

### Stub Simulators

`VoucherSimulator`, `CancellationSimulator`, `DeliverySimulator`, `NotificationSimulator` all expose a single `execute(params:)` method that returns `{ success: true, reference: SecureRandom.hex(8) }` and accept a configurable `failure_rate:` for testing error paths.

---

## Real-Time Dashboard Design

### Routes

```ruby
# config/routes.rb
root "dashboard#index"

resources :orders, only: [:index, :show] do
  resources :failure_injections, only: [:create]
end

resources :approval_requests, only: [] do
  member do
    post :approve
    post :reject
  end
end
```

### Turbo Stream Channels

| Channel | Target DOM ID | Updated by |
|---|---|---|
| `orders` (global) | `order_stream` | `Order` AASM after_transition callback |
| `orders` (global) | `failure_feed` | `FailureEvent` after_create callback |
| `orders` (global) | `recovery_queue` | `RecoveryOrchestrator` at each stage |
| `orders` (global) | `approval_queue` | `ApprovalRequest` after_create callback |
| `orders` (global) | `system_metrics` | `AuditEvent` after_create callback (debounced) |
| `order_<id>` | `audit_timeline_<id>` | `AuditLogger` after every record |

Broadcasts are triggered from model `after_commit` callbacks and service layer calls — never from controllers.

```ruby
# app/models/order.rb
after_commit :broadcast_to_order_stream

def broadcast_to_order_stream
  broadcast_replace_to "orders",
    target: "order_#{id}",
    partial: "orders/order_row",
    locals: { order: self }
end
```

### Solid Cable

```ruby
# app/channels/orders_channel.rb
class OrdersChannel < ActionCable::Channel::Base
  def subscribed
    stream_from "orders"
  end
end

# app/channels/order_channel.rb
class OrderChannel < ActionCable::Channel::Base
  def subscribed
    stream_from "order_#{params[:order_id]}"
  end
end
```

`config/cable.yml` uses the Solid Cable adapter (database-backed, no Redis).

### Stimulus Controllers

**`elapsed-timer-controller`** — Manages the live elapsed-time display in the Approval Queue panel.

```javascript
// app/javascript/controllers/elapsed_timer_controller.js
// Reads data-started-at-value, updates display every 1 second
// Stops when the element is removed from the DOM (via Turbo Stream replacement)
```

**`failure-injection-controller`** — Handles the per-order failure type selection and submission with inline confirmation.

### Dashboard Panels

```
┌─────────────────────────────────────────────────────────────────────┐
│ OrderOps Dashboard                                           [metrics]│
├──────────────────────┬──────────────────────┬───────────────────────┤
│   Order Stream        │   Failure Feed        │  Recovery Queue        │
│   #order_stream       │   #failure_feed       │  #recovery_queue       │
│                       │                       │                        │
│ [PREPARING] ord-001 🟡│ KITCHEN_FAILURE       │ ord-001 → REROUTE     │
│ [PENDING]   ord-002 🟢│ [injected] 2s ago     │  AI: reroute 0.85     │
│ [PENDING_APPROVAL] 🔴 │                       │  Status: executing    │
├──────────────────────┴──────────────────────┬┴───────────────────────┤
│   Approval Queue                              │  Audit Timeline         │
│   #approval_queue                             │  #audit_timeline        │
│                                               │                         │
│ ord-003 FULL_REFUND $75                       │ Select order to view   │
│ Confidence: 90%  Elapsed: 00:45               │ chronological events   │
│ [Approve] [Reject]                            │                         │
└───────────────────────────────────────────────┴─────────────────────────┘
```

---

## Correctness Properties

*A property is a characteristic or behavior that should hold true across all valid executions of a system — essentially, a formal statement about what the system should do. Properties serve as the bridge between human-readable specifications and machine-verifiable correctness guarantees.*

### Property 1: State machine transition table is exhaustive and exclusive

*For any* `(from_state, to_state)` pair drawn from all possible combinations of the 12 defined states, the `OrderStateMachine` either succeeds (if the pair is in the allowed transition table) or raises `AASM::InvalidTransition` (if the pair is not in the table). No pair returns nil or raises an unexpected error type.

**Validates: Requirements 1.2, 1.4, 1.7**

---

### Property 2: Every valid transition produces an AuditEvent and preserves state

*For any* valid `(from_state, to_state)` transition, after the transition: (a) `AuditEvent` count for the order increases by at least 1, and (b) the `AuditEvent` has `event_type: "order_state_changed"`, `from_state` matching the pre-transition state, and `to_state` matching the post-transition state.

**Validates: Requirements 1.3, 8.2**

---

### Property 3: Invalid transitions leave Order state unchanged

*For any* invalid `(from_state, to_state)` pair, after a failed transition attempt, `Order.state` equals the same value it had before the attempt.

**Validates: Requirements 1.4**

---

### Property 4: AuditEvent log is monotonically non-decreasing (append-only)

*For any* order and any sequence of system operations, the count of `AuditEvent` records for that order after the operation is always greater than or equal to the count before the operation. The count never decreases.

**Validates: Requirements 8.3**

---

### Property 5: AuditEvent records for an order are always retrievable in occurred_at ascending order

*For any* order with N `AuditEvent` records created in any insertion order, `Order#audit_events` returns exactly N records ordered by `occurred_at` ascending.

**Validates: Requirements 1.6, 8.6**

---

### Property 6: PolicyEngine is deterministic (pure function)

*For any* fixed `PolicyInput`, calling `PolicyEngine.evaluate(input:)` 100 times always produces an identical `PolicyDecision` (same `status`, `requires_human_approval`, `reason`, `guardrail_violated`).

**Validates: Requirements 4.7, 7.3**

---

### Property 7: PolicyEngine guardrails cover all denial conditions

*For any* `PolicyInput` that violates exactly one of guardrails G1–G6, `PolicyEngine.evaluate` returns `status: :denied` with `guardrail_violated` identifying the specific guardrail, without consulting configurable policy checks.

**Validates: Requirements 4.1, 4.2, 4.3, 9.1, 9.2**

---

### Property 8: PolicyEngine human-approval triggers are boundary-correct

*For any* `PolicyInput` with a `full_refund` action and `total_cents` strictly above `human_approval_refund_threshold_cents`, `PolicyDecision.requires_human_approval` is `true`. *For any* input with `total_cents` at or below the threshold (all other conditions allowing auto-approval), `requires_human_approval` is `false`.

**Validates: Requirements 4.5, 4.6, 7.6**

---

### Property 9: RecoveryAgent context object raises NotImplementedError for all prohibited methods

*For every* method name in the five prohibited categories (Order record mutation, RecoveryAction mutation, AuditEvent mutation, simulator mutation methods, ActionExecutor calls), calling that method on a `RecoveryContext` instance raises `NotImplementedError` whose message includes the method name.

**Validates: Requirements 3.6, 11.1a, 11.1b**

---

### Property 10: FakeProvider is idempotent for any (failure_type, order_state) pair

*For any* `failure_type` and any `order_state`, calling `FakeProvider#diagnose` 100 times with the same inputs always returns an identical ordered array of `Proposal` objects (same `action_type`, `confidence`, `reasoning`, `estimated_customer_impact` for each position).

**Validates: Requirements 3.9**

---

### Property 11: RecoveryAgent response always conforms to schema

*For any* provider response (including edge cases: single proposal, maximum confidence 1.0, empty reasoning), the structured response passes schema validation and round-trips through JSON serialization/deserialization to produce an equivalent object without data loss.

**Validates: Requirements 3.2, 3.5**

---

### Property 12: FailureInjector never creates FailureEvent for terminal orders

*For any* terminal order state (`delivered`, `cancelled`, `recovered`) and any failure type, calling `FailureInjector.inject` raises `TerminalOrderError` and leaves `FailureEvent` count unchanged.

**Validates: Requirements 2.5**

---

### Property 13: ActionExecutor raises PolicyBypassError without prior policy approval AuditEvent

*For any* `RecoveryAction`, calling `ActionExecutor.execute` without a matching `policy_evaluation` AuditEvent with `payload.status: "APPROVED"` for the same order raises `PolicyBypassError` and the action is not executed.

**Validates: Requirements 6.2, 11.3 (AC3)**

---

### Property 14: At most one pending ApprovalRequest per Order

*For any* order that already has an `ApprovalRequest` with `status: :pending`, attempting to insert a second pending `ApprovalRequest` for the same order raises `ActiveRecord::RecordNotUnique`.

**Validates: Requirements 7.5**

---

### Property 15: RestaurantSimulator exclusion invariant

*For any* order with a set R of restaurants that have previously rejected it (evidenced by `restaurant_rejected` AuditEvents), `RestaurantSimulator#available_for(excluding_restaurant_ids: R)` never includes any restaurant from R in its result.

**Validates: Requirements 6.9 (REQ-06 AC-06.2 / AC-04.2)**

---

### Property 16: FailureEvent.injected is always explicitly set

*For any* `FailureEvent` created through any code path, `injected` is never `nil` — it is always `true` (FailureInjector path) or `false` (natural detection path).

**Validates: Requirements 2.3, 8.8**

---

## Error Handling

### RecoveryOrchestrator Error Matrix

| Failure point | RecoveryOrchestrator action | Order final state | AuditEvent |
|---|---|---|---|
| `RecoveryAgent` raises or times out | Apply fallback strategy | Continues pipeline | `ai_error` or `ai_fallback` |
| `RecoveryAgent` returns invalid schema | Apply fallback strategy | Continues pipeline | `ai_validation_error` |
| `PolicyEngine` raises unhandled exception | Transition to FAILED; halt | `FAILED` | `policy_error` |
| All proposals denied by PolicyEngine | Create ESCALATE_TO_HUMAN | `PENDING_APPROVAL` | `escalated_to_human` |
| `ActionExecutor` raises | Transition to FAILED; halt | `FAILED` | `execution_error` |
| `RestaurantSimulator` returns no results | `ActionExecutor` raises `NoRestaurantAvailableError`; try next proposal | Continues pipeline or `PENDING_APPROVAL` | `execution_error` |
| Solid Queue job fails after all retries | Leave in last valid state | Unchanged | `orchestration_exhausted` |
| `PolicyConfig` missing at boot | Application refuses to start | N/A | N/A (startup error) |

### `ActionExecutor` Error Contracts

- `PolicyBypassError` — raised when no valid policy approval AuditEvent exists. Never retried.
- `UnauthorizedCallError` — raised when ActionExecutor is called outside the authorized orchestration context.
- `NoRestaurantAvailableError` — raised by RestaurantSimulator when no matching restaurant exists. RecoveryOrchestrator catches this and advances to the next proposal.
- All simulator errors bubble up as `ActionExecutor::ExecutionError` wrapping the original.

### Dashboard Error Display

Inline Turbo Stream error messages are rendered for: failed failure injection, failed approval submission. Errors never result in full page redirects.

---

## Testing Strategy

### Unit Tests

**`OrderStateMachine`** (RSpec + AASM)
- All 12 states defined
- All valid transitions succeed; all invalid transitions raise `AASM::InvalidTransition`
- Each transition records a state_changed AuditEvent
- `with_lock` called on every transition (verified with `expect(order).to receive(:lock!)`)
- Property tests (see below) cover exhaustive transition matrix

**`PolicyEngine`**
- Each of the 6 guardrail rules independently — with inputs designed to trigger only that rule
- Each of the 5 human-approval triggers — boundary values (threshold ± 1)
- 100% branch coverage target
- Property tests verify determinism and completeness

**`RecoveryAgent`** (FakeProvider)
- Deterministic response for each failure type
- Fallback on provider timeout
- Fallback on schema validation failure
- `RecoveryContext` prohibited methods raise `NotImplementedError`
- Shared example group `"AI advisory boundary"` included in all RecoveryAgent specs

**`FailureInjector`**
- Creates FailureEvent with `injected: true`
- Raises `TerminalOrderError` for terminal orders (all 4 terminal states)
- Enqueues `RecoveryOrchestratorJob`

**`ActionExecutor`**
- Each of 8 action types dispatches to correct simulator
- `PolicyBypassError` when no policy AuditEvent
- `UnauthorizedCallError` when called outside orchestration
- `RecoveryAction.status` is `:executed` after success
- `RecoveryAction.status` is `:failed` after simulator error

**`AuditLogger`**
- Created record has all required fields
- No `update` or `delete` calls succeed on `AuditEvent`
- Broadcasts Turbo Stream update after creation

### Integration Tests

**`RecoveryOrchestrator` pipeline** (full pipeline with FakeProvider + simulators)
- Scenario 1 path: FailureEvent → REROUTE → RECOVERED, all AuditEvents in correct sequence
- Scenario 2 path: FailureEvent → FULL_REFUND → PENDING_APPROVAL → (ResumptionJob) → RECOVERED
- All-proposals-denied path: → ESCALATE_TO_HUMAN → PENDING_APPROVAL
- ActionExecutor error path: → FAILED, `execution_error` AuditEvent
- Concurrent state transitions: two threads, assert final state is consistent

**Turbo Stream broadcasting**
- Order stream panel receives broadcast on state change
- Approval queue receives broadcast on ApprovalRequest creation
- Audit timeline receives broadcast on AuditEvent creation

### System Specs (RSpec + Capybara)

These map directly to the two demo scenarios from the requirements document.

**Demo Scenario 1 — Automatic Restaurant Reroute:**
```ruby
scenario "automatic restaurant reroute from kitchen failure" do
  order = create(:order, :preparing, total_cents: 2500)
  # ... inject failure, run jobs, assert Order in RECOVERED, assert AuditEvent sequence
end
```

**Demo Scenario 2 — Human Approval for Full Refund:**
```ruby
scenario "full refund with human approval" do
  order = create(:order, :in_delivery, total_cents: 7500)
  # ... inject failure, run jobs, assert PENDING_APPROVAL
  # ... operator approves via dashboard
  # ... run ResumptionJob, assert Order in RECOVERED
end
```

### Property-Based Tests

**Gem:** `rantly` — a property-based testing library for Ruby that integrates with RSpec via `Rantly::RSpec::Property` helpers. Minimum 100 iterations per property.

**Test file organization:**
```
spec/properties/
  order_state_machine_properties_spec.rb   # Properties 1, 2, 3
  audit_event_properties_spec.rb           # Properties 4, 5, 16
  policy_engine_properties_spec.rb         # Properties 6, 7, 8
  recovery_agent_properties_spec.rb        # Properties 9, 10, 11
  failure_injector_properties_spec.rb      # Property 12
  action_executor_properties_spec.rb       # Property 13
  approval_request_properties_spec.rb      # Property 14
  restaurant_simulator_properties_spec.rb  # Property 15
```

Each property test carries a comment tag:
```ruby
# Feature: safe-order-recovery, Property 6: PolicyEngine is deterministic
property "PolicyEngine.evaluate is deterministic for any PolicyInput" do
  Rantly.value(100) do
    # generate random PolicyInput...
    results = 100.times.map { PolicyEngine.evaluate(input: input) }
    expect(results.uniq.length).to eq(1)
  end
end
```

### Shared Example Groups

```ruby
# spec/support/shared_examples/ai_advisory_boundary.rb
RSpec.shared_examples "AI advisory boundary" do
  PROHIBITED_METHODS = [
    # Category i: Order record mutation
    :save, :update, :update!, :destroy, :create, :assign_attributes,
    :pending!, :assigned!, :failed!, :recovered!, :cancel!,
    # Category ii: RecoveryAction mutation
    :create_recovery_action!, :update_recovery_action!,
    # Category iii: AuditEvent mutation
    :create_audit_event!, :update_audit_event!,
    # Category iv: Simulator mutations
    :refund, :cancel, :reroute, :issue_voucher,
    # Category v: ActionExecutor calls
    :execute_action, :dispatch_to_executor
  ].freeze

  PROHIBITED_METHODS.each do |method_name|
    it "raises NotImplementedError when #{method_name} is called" do
      expect { subject.public_send(method_name) }
        .to raise_error(NotImplementedError, /#{method_name}/)
    end
  end
end
```

---

## Key Architectural Trade-offs

### 1. AASM vs `state_machines-activerecord`

**Chosen:** AASM.

AASM has more explicit callback composition (`before_all_transitions`, `after_all_transitions`, named event callbacks), cleaner guard syntax, and broader community adoption. `state_machines-activerecord` has a richer automatic `scope` generation feature, but we don't need it — all our state queries use explicit `where(state:)` clauses. AASM's `whiny_transitions: true` gives us free `AASM::InvalidTransition` errors without custom guard code.

### 2. RecoveryOrchestrator Resumption: ResumptionJob vs Polling

**Chosen:** `ResumptionJob` enqueued by the `ApprovalRequestsController` on approval.

The alternative — having `RecoveryOrchestrator` poll for an approved `ApprovalRequest` — would require either sleeping (blocking a Solid Queue thread) or periodic job re-enqueueing (complex retry logic). `ResumptionJob` is a separate, lightweight job that picks up exactly where the orchestrator left off. It avoids re-running the AI and policy steps. The trade-off: the orchestrator pipeline is not a single uninterrupted execution, which makes it slightly harder to trace in the job queue. This is mitigated by the `AuditEvent` trail which records every step regardless of which job executed it.

### 3. PolicyEngine as Pure Function (No ActiveRecord)

**Chosen:** Pure function, all data passed as arguments.

The alternative would be having `PolicyEngine` query `AuditEvent` and `RecoveryAction` records directly. That would make it impossible to unit-test in isolation and would couple the policy logic to the database schema. The trade-off: callers (`RecoveryOrchestrator`) must assemble the `PolicyInput` correctly, which requires an `AuditHistory` loader helper. This is a small but real added complexity. The benefit — 100% deterministic, independently testable policy evaluation — is worth it for a safety-critical component.

### 4. Single LLM Call vs Multi-Agent Chain

**Chosen:** Single structured LLM call per `RecoveryAgent.diagnose` invocation.

Multi-agent chains (diagnose → propose → estimate impact) would allow each step to be independently observable and auditable. But for a demo platform with a `FakeProvider` default, the added complexity of chain coordination, error handling at each step, and the latency accumulation in a real-LLM scenario outweigh the benefits. The single call returns a structured JSON response with all required fields. The interface is designed so that swapping to a multi-call chain is a provider-internal change that doesn't affect `RecoveryOrchestrator`.

### 5. AuditEvent as PostgreSQL Table vs Event-Sourcing Framework

**Chosen:** Plain PostgreSQL table with append-only enforcement.

Event-sourcing frameworks (e.g., RailsEventStore) would give us projections, event replay, and a richer subscriber model. But they add a significant dependency and conceptual overhead for a demo platform. The append-only PostgreSQL table with a `before_update` / `before_destroy` callback that always raises is sufficient for V1. The trade-off: no built-in event replay (we reconstruct state from the `Order` table, not from events), and no subscriber model beyond the Turbo Stream broadcast in `AuditLogger`. This is an explicit V1 scoping decision.

### 6. In-Process Simulators vs Real Adapter Interface

**Chosen:** In-process simulators with a thin interface contract.

The simulators conform to an interface (`available_for`, `refund`, etc.) that is identical to what a real integration would implement. This means swapping a simulator for a real adapter is a class substitution, not a design change. The trade-off: we never actually test the integration boundary in V1. This is mitigated by ADR-02: the point of V1 is demo fidelity and correctness, not integration coverage.

---

## File / Directory Structure

```
app/
├── models/
│   ├── order.rb
│   ├── concerns/
│   │   └── order_state_machine.rb
│   ├── failure_event.rb
│   ├── recovery_action.rb
│   ├── approval_request.rb
│   └── audit_event.rb
│
├── services/
│   ├── failure_injector.rb
│   ├── recovery_agent.rb
│   ├── recovery_context.rb
│   ├── policy_engine.rb
│   ├── action_executor.rb
│   ├── audit_logger.rb
│   ├── policy_config.rb
│   └── providers/
│       ├── fake_provider.rb
│       ├── bedrock_provider.rb
│       └── open_ai_provider.rb
│
├── jobs/
│   ├── recovery_orchestrator_job.rb
│   ├── resumption_job.rb
│   └── approval_timeout_job.rb
│
├── simulators/
│   ├── restaurant_simulator.rb
│   ├── payment_simulator.rb
│   ├── voucher_simulator.rb
│   ├── cancellation_simulator.rb
│   ├── delivery_simulator.rb
│   └── notification_simulator.rb
│
├── controllers/
│   ├── dashboard_controller.rb
│   ├── orders_controller.rb
│   ├── failure_injections_controller.rb
│   └── approval_requests_controller.rb
│
├── views/
│   ├── dashboard/
│   │   └── index.html.erb
│   ├── orders/
│   │   ├── _order_row.html.erb
│   │   └── show.html.erb
│   ├── approval_requests/
│   │   ├── _approval_request.html.erb
│   │   └── _approved.html.erb
│   ├── recovery_actions/
│   │   └── _recovery_action.html.erb
│   ├── failure_events/
│   │   └── _failure_event.html.erb
│   └── audit_events/
│       └── _audit_event.html.erb
│
├── javascript/
│   └── controllers/
│       ├── elapsed_timer_controller.js
│       └── failure_injection_controller.js
│
└── channels/
    ├── orders_channel.rb
    └── order_channel.rb

config/
├── policy_config.yml
├── initializers/
│   ├── policy_config.rb
│   └── recovery_agent.rb
└── cable.yml

spec/
├── models/
│   ├── order_spec.rb
│   └── audit_event_spec.rb
├── services/
│   ├── failure_injector_spec.rb
│   ├── recovery_agent_spec.rb
│   ├── policy_engine_spec.rb
│   ├── action_executor_spec.rb
│   └── audit_logger_spec.rb
├── jobs/
│   ├── recovery_orchestrator_job_spec.rb
│   └── resumption_job_spec.rb
├── simulators/
│   ├── restaurant_simulator_spec.rb
│   └── payment_simulator_spec.rb
├── properties/
│   ├── order_state_machine_properties_spec.rb
│   ├── audit_event_properties_spec.rb
│   ├── policy_engine_properties_spec.rb
│   ├── recovery_agent_properties_spec.rb
│   ├── failure_injector_properties_spec.rb
│   ├── action_executor_properties_spec.rb
│   ├── approval_request_properties_spec.rb
│   └── restaurant_simulator_properties_spec.rb
├── system/
│   ├── demo_scenario_1_spec.rb
│   └── demo_scenario_2_spec.rb
├── support/
│   ├── shared_examples/
│   │   └── ai_advisory_boundary.rb
│   └── factories/
│       ├── orders.rb
│       ├── failure_events.rb
│       ├── recovery_actions.rb
│       ├── approval_requests.rb
│       └── audit_events.rb
└── rails_helper.rb
```
