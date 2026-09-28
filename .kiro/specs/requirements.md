# OrderOps — Requirements and Acceptance Criteria

**Version:** 0.3  
**Stack:** Ruby on Rails 8.1.4 · PostgreSQL · Solid Queue · Solid Cable · Hotwire

## Overview

OrderOps is an AI-powered Order Reliability and Recovery Platform for food ordering systems. It monitors the order lifecycle, detects risk and failure conditions, determines safe recovery options, and executes or escalates recovery actions — always under the control of a deterministic policy engine.

### Guiding principle

> AI reasons and recommends. Deterministic policies decide what is allowed. Application services execute approved actions. An LLM must never directly call mutation functions, issue refunds, or change order state.

### Fixed evaluation pipeline

Every recovery action passes through this pipeline in order. No stage may be skipped:

```
AI recommendation → Policy evaluation → [Human approval if high-risk] → Execution
```

---

## Functional Requirements

### REQ-01 — Order Lifecycle and State Management

#### Description
The system must represent every order as a state machine with a well-defined set of states and allowed transitions. The state machine is the authoritative record of where an order is in its lifecycle. Concurrent transitions are controlled via optimistic concurrency on a `lock_version` column.

#### Order Data Model
Every order record in PostgreSQL carries the following fields:

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | Primary key |
| `customer_id` | UUID | |
| `restaurant_id` | UUID | Nullable until assigned |
| `state` | string | Enum value; see state list below |
| `lock_version` | integer | Rails optimistic locking |
| `items` | jsonb | Array of `{name, quantity, unit_price, currency}` |
| `order_total` | decimal(10,2) | |
| `currency` | string(3) | ISO 4217 |
| `delivery_address` | jsonb | `{street, city, postcode, lat, lng}` |
| `payment_intent_id` | string | Simulator payment reference |
| `sla_started_at` | timestamp | When current SLA phase began |
| `sla_phase` | string | Current SLA phase name |
| `customer_recovery_preferences` | jsonb | Nullable: `{preferred_action, contact_method}` |
| `cuisine_type` | string | Used by router |
| `rejected_restaurant_ids` | uuid[] | Restaurants that have rejected this order |
| `reroute_attempt_count` | integer | Default 0 |
| `created_at` / `updated_at` | timestamp | |

#### States
| State | Meaning |
|---|---|
| `pending` | Order created, awaiting restaurant assignment |
| `assigned` | Restaurant assigned, awaiting acceptance |
| `accepted` | Restaurant accepted, awaiting preparation start |
| `preparing` | Kitchen is preparing the order |
| `ready_for_pickup` | Order ready, awaiting courier |
| `in_delivery` | Courier has picked up the order |
| `delivered` | Order successfully delivered |
| `failed` | Non-terminal failure — recovery may be attempted |
| `cancelled` | Order cancelled by system, customer, or policy |
| `recovered` | Order completed via a recovery path |
| `pending_approval` | Recovery action proposed; waiting for human approval |
| `recovering` | Approved recovery action is executing |

#### Allowed Transitions
- `pending` → `assigned`, `cancelled`
- `assigned` → `accepted`, `failed`, `pending` (re-route returns to pending)
- `accepted` → `preparing`, `failed`
- `preparing` → `ready_for_pickup`, `failed`
- `ready_for_pickup` → `in_delivery`, `failed`
- `in_delivery` → `delivered`, `failed`
- `failed` → `pending_approval`, `recovering`, `cancelled`
- `pending_approval` → `recovering`, `cancelled`
- `recovering` → `recovered`, `failed`

#### Acceptance Criteria
- AC-01.1: Every order has a UUID primary key and a persisted current state in PostgreSQL.
- AC-01.2: An invalid state transition is rejected with a descriptive error; the order state does not change.
- AC-01.3: Every state transition produces a timestamped audit record (see REQ-11).
- AC-01.4: The system can retrieve full order state and metadata by order ID.
- AC-01.5: Concurrent state transition attempts on the same order raise `ActiveRecord::StaleObjectError` for the losing writer; the winning transition is persisted; the loser can retry.
- AC-01.6: All order state transitions go through `OrderStateMachine`; no code sets `order.state=` directly outside that class.

---

### REQ-02 — Event-Driven Order Monitoring

#### Description
Order events must be published to an internal event bus. The V1 implementation dispatches events via **Solid Queue** — the Rails 8.1 default database-backed ActiveJob adapter. No Redis is required. The event bus is accessed only through the `EventBus` abstraction, making the backing implementation swappable.

#### Event Types
- `order.created`, `order.state_changed`
- `restaurant.accepted`, `restaurant.rejected`, `restaurant.unavailable`
- `inventory.failure`
- `kitchen.delay`, `kitchen.failure`
- `delivery.delay`, `delivery.failure`
- `payment.failure`
- `sla.warning`, `sla.breached`
- `failure.injected`
- `recovery.proposed`, `recovery.approved`, `recovery.rejected`, `recovery.executed`
- `approval.requested`, `approval.received`

#### Event Structure
Every domain event carries:
- `event_id` — UUID (used for deduplication)
- `event_type` — string from the list above
- `order_id` — UUID
- `sequence_number` — integer, per-order monotonically increasing
- `occurred_at` — UTC timestamp
- `subsystem` — originating component
- `payload` — type-specific hash

#### Acceptance Criteria
- AC-02.1: All inter-subsystem communication for order status changes goes through `EventBus`; no subsystem calls another's state-mutation methods directly.
- AC-02.2: Every event includes `event_id`, `event_type`, `order_id`, `sequence_number`, `occurred_at`, `subsystem`, and `payload`.
- AC-02.3: Consumers deduplicate events by `event_id` before processing; a duplicate event does not trigger a second action.
- AC-02.4: The system supports at-least-once delivery; consumers are idempotent (see REQ-06, ADR-10).
- AC-02.5: An exception in one event handler does not prevent other handlers from receiving the same event.
- AC-02.6: A `SynchronousEventBusAdapter` is available for use in tests, delivering events inline without background jobs.

---

### REQ-03 — SLA Monitoring and Breach Detection

#### Description
Each order phase has a configurable time budget. An ActiveJob recurring task (or Sidekiq scheduler) evaluates all active orders at a configurable tick interval and emits warning and breach events.

#### SLA Phases and Default Budgets
| Phase | Warning threshold | Breach threshold |
|---|---|---|
| Restaurant assignment | 60 s | 120 s |
| Restaurant acceptance | 90 s | 180 s |
| Order preparation | 600 s | 900 s |
| Pickup wait | 120 s | 240 s |
| Delivery | 1800 s | 2700 s |
| End-to-end (created → delivered) | 2700 s | 3600 s |

All thresholds are configurable in `config/orderops.yml`.

#### Acceptance Criteria
- AC-03.1: The SLA monitor evaluates all non-terminal orders at least once per configurable tick interval (default: 10 s in simulation mode).
- AC-03.2: An `sla.warning` event is emitted when a phase reaches its warning threshold; it is not re-emitted on every tick while the phase remains in warning.
- AC-03.3: An `sla.breached` event is emitted when a phase exceeds its breach threshold; it is not re-emitted on every tick while breached.
- AC-03.4: SLA events include: order ID, phase name, elapsed seconds, threshold crossed.
- AC-03.5: All SLA thresholds are read from `config/orderops.yml`; no threshold value is hard-coded.
- AC-03.6: Once an order reaches a terminal state (`delivered`, `cancelled`, `recovered`), SLA monitoring stops for that order.
- AC-03.7: The dashboard shows a live count of orders in `warning` and `breached` SLA state, updated via Turbo Streams.

---

### REQ-04 — Restaurant Routing and Re-Routing

#### Description
The `RestaurantRouter` service selects the best available restaurant from the simulator pool. It does not mutate order state; it returns a routing decision that the orchestrator applies via the state machine.

#### Routing Criteria (priority order)
1. Restaurant is available (not at capacity, not marked unavailable)
2. Restaurant supports the required cuisine type
3. Restaurant is within configurable maximum distance from delivery address
4. Restaurant has the lowest current queue depth

#### Re-Routing Triggers
- Restaurant rejects the order (`restaurant.rejected` event)
- Restaurant becomes unavailable after acceptance (`restaurant.unavailable` event)
- SLA breach in `accepted` or `preparing` state with a recoverable failure
- Approved `REROUTE_RESTAURANT` recovery action

#### Acceptance Criteria
- AC-04.1: `RestaurantRouter` returns the top-ranked available restaurant or a `RoutingResult::NoRestaurantAvailable` value object with a reason string.
- AC-04.2: A restaurant whose ID appears in `order.rejected_restaurant_ids` is excluded from candidates.
- AC-04.3: `RestaurantRouter` returns a `RoutingDecision` value object; it never writes to the `orders` table directly.
- AC-04.4: If no restaurant is available, the order transitions to `failed` and an escalation event is emitted.
- AC-04.5: The restaurant simulator exposes a `mark_unavailable(restaurant_id)` method used in failure injection.
- AC-04.6: Every routing decision (selected or rejected) produces an audit record with the reason.

---

### REQ-05 — Failure Detection and Injection

#### Description
The `FailureDetector` listens to simulator callbacks and external events, translating them into typed domain failure events. The `FailureInjector` provides a deterministic injection API available in `development` and `demo` environments only.

#### Detectable Failure Types
| Code | Description |
|---|---|
| `RESTAURANT_REJECTION` | Restaurant explicitly rejects the order |
| `RESTAURANT_UNAVAILABLE` | Restaurant goes offline after acceptance |
| `INVENTORY_FAILURE` | Item(s) unavailable |
| `KITCHEN_DELAY` | Preparation exceeding SLA |
| `KITCHEN_FAILURE` | Hard kitchen failure |
| `DELIVERY_DELAY` | Delivery exceeding SLA |
| `DELIVERY_FAILURE` | Courier hard failure |
| `PAYMENT_FAILURE` | Payment declined or error |
| `EXTERNAL_SERVICE_FAILURE` | Simulator integration failure |

#### Failure Injection API
```ruby
FailureInjector.inject(order_id:, failure_type:, delay_seconds: 0)
FailureInjector.inject_at_state(order_id:, failure_type:, trigger_state:)
FailureInjector.clear_pending(order_id:)
```

Raises `FailureInjector::NotAvailableInEnvironment` in `production` and `staging`.

#### Acceptance Criteria
- AC-05.1: Each detected failure publishes a typed failure event with: failure code, order ID, subsystem, description string.
- AC-05.2: `FailureInjector` can inject any failure type against any active order in `development`/`demo` environments.
- AC-05.3: Injected failures pass through the same `FailureDetector` pipeline as natural failures.
- AC-05.4: Injected failure events carry `injected: true` in their payload; this is stored in the audit record's `injected` column.
- AC-05.5: `FailureInjector.inject` raises `OrderNotActive` if the order is in a terminal state.
- AC-05.6: `FailureInjector` raises `NotAvailableInEnvironment` when called in `production` or `staging`.
- AC-05.7: All nine failure types listed above are handled by `FailureDetector`.

---

### REQ-06 — Recovery Orchestration

#### Description
The `RecoveryOrchestrator` background job coordinates the full recovery pipeline: AI diagnosis → policy validation → human approval (if required) → idempotent execution → state verification → audit.

`RecoveryOrchestratorJob` includes `ActiveJob::Continuable` (Rails 8.1) so that each stage of the pipeline is a discrete step. If the job is interrupted mid-pipeline (deploy, crash), execution resumes from the last completed step rather than re-running the AI call or re-executing a completed action.

#### Recovery Actions
| Action | Description |
|---|---|
| `REROUTE_RESTAURANT` | Assign a different restaurant |
| `PARTIAL_REFUND` | Issue a partial refund and continue |
| `FULL_REFUND` | Cancel and fully refund |
| `ISSUE_VOUCHER` | Issue a compensation voucher |
| `ESCALATE_TO_HUMAN` | Request human operator decision |
| `CANCEL_ORDER` | Cancel (policy-defined conditions) |
| `RETRY_DELIVERY` | Attempt delivery re-assignment |
| `CONTACT_CUSTOMER` | Flag for customer notification |

#### Recovery Flow
1. Failure or SLA breach event received by `RecoveryOrchestrator`
2. AI agent diagnoses and proposes ranked recovery actions (REQ-08)
3. Policy engine validates each proposed action (REQ-09), in the pipeline order defined in ADR-13
4. If approved and not high-risk: `ActionExecutor` executes immediately
5. If approved and high-risk: `ApprovalQueue` record created; order → `pending_approval`
6. If rejected by policy: next candidate is evaluated; if all rejected, `ESCALATE_TO_HUMAN`
7. `ActionExecutor` uses idempotency key (ADR-10) before calling simulator
8. Post-execution: order state verified; `recovery.executed` event published
9. All steps produce audit records (REQ-11)

#### Acceptance Criteria
- AC-06.1: `RecoveryOrchestrator` handles all nine failure types and produces at least one candidate recovery action.
- AC-06.2: `ActionExecutor` is never called without a prior `PolicyEngine` approval result for the same action and order.
- AC-06.3: If all candidate actions are policy-denied, the order is escalated to human.
- AC-06.4: Recovery execution transitions order state via `OrderStateMachine`, never directly.
- AC-06.5: `recovery.proposed`, `recovery.approved`/`recovery.rejected`, and `recovery.executed` events are published.
- AC-06.6: An execution failure leaves the order in `failed` state and emits an escalation event; the error is not silently swallowed.
- AC-06.7: Concurrent `RecoveryOrchestrator` jobs for different orders do not interfere; concurrent jobs for the *same* order are prevented by the idempotency key constraint.
- AC-06.8: `RecoveryOrchestratorJob` uses `ActiveJob::Continuable`; if interrupted after the AI step but before execution, resuming the job does not re-invoke the LLM — it resumes from the policy evaluation step using the stored AI output.

---

### REQ-07 — Refund and Compensation Policy Management

#### Description
All refund and compensation rules are defined in `config/orderops_policy.yml`. A `PolicyConfiguration` Ruby object is loaded at startup and injected into `PolicyEngine`. The configuration file includes a `version` string.

#### Policy Dimensions in `orderops_policy.yml`
- `refund_eligibility`: failure types → eligible order states → time window
- `compensation`: amounts (percentage or fixed) per failure type
- `voucher_rules`: when vouchers may substitute or supplement refunds
- `approval_thresholds`: conditions requiring human approval
- `cooldown`: minimum interval between compensations per customer
- `fallback_recovery`: default action per failure type (used by AI fallback, ADR-08)
- `reroute_limit`: maximum reroute attempts per order (default: 3)
- `full_refund_approval_threshold`: order total above which `FULL_REFUND` always requires approval (default: 50.00)

#### Acceptance Criteria
- AC-07.1: All refund and compensation rules are in `config/orderops_policy.yml`; no thresholds or limits are hard-coded.
- AC-07.2: `PolicyEngine.evaluate(action, order, context)` returns a `PolicyDecision` with `approved: true/false` and `reason: string`.
- AC-07.3: Policy evaluation is a pure function — same inputs always produce the same output; no database reads or external I/O.
- AC-07.4: The policy version from `orderops_policy.yml` is written to the `policy_version` column of every audit record produced during policy evaluation.
- AC-07.5: The default `orderops_policy.yml` defines rules for all nine failure types in REQ-05.
- AC-07.6: A `FULL_REFUND` on an order whose `order_total` exceeds `full_refund_approval_threshold` always returns `approved: false, requires_human_approval: true`, regardless of other policy conditions.

---

### REQ-08 — AI-Assisted Failure Diagnosis and Recovery Planning

#### Description
The `LlmAgent` service invokes the configured `LlmProvider` with a structured prompt and validates the response against a JSON schema before passing proposals to `PolicyEngine`. The AI cannot call any function that mutates order state or executes financial operations.

#### AI Agent Inputs (read-only context passed to prompt)
- Current order state and non-PII metadata (order ID, state, items summary, totals, SLA status, reroute count)
- Full domain event history for the order (event type, subsystem, occurred_at, payload)
- Failure type and description
- Available action types (from the defined list in REQ-06)
- Restaurant availability summary (count, cuisine types available)

#### Required AI Output Schema
Each proposed action must conform to:
```json
{
  "action_type": "<string: one of the defined recovery action types>",
  "confidence": "<float: 0.0 to 1.0>",
  "reasoning": "<string: plain-language explanation, no PII>",
  "evidence": ["<string>", "..."],
  "estimated_customer_impact": "<LOW|MEDIUM|HIGH>"
}
```

The response is an array of such objects, ordered by descending confidence.

#### Constraints (enforced structurally, not by convention)
- `LlmProvider` implementations expose only `complete(prompt) → string`. They have no access to `OrderStateMachine`, `ActionExecutor`, `PolicyEngine`, or any simulator.
- `LlmAgent` passes only a read-only context struct to the provider — not ActiveRecord objects.
- The prompt template must not include customer PII fields (`customer_id` is included as an opaque UUID reference only).

#### Acceptance Criteria
- AC-08.1: For every detected failure, `LlmAgent` produces at least one proposed recovery action within the configured timeout (default: 15 s).
- AC-08.2: AI output is parsed and validated against the JSON schema before being passed to `PolicyEngine`; invalid output triggers the fallback (AC-08.3).
- AC-08.3: If the AI call fails, times out, or returns invalid output, `LlmAgent` returns the deterministic fallback actions from `orderops_policy.yml` with `confidence: 0.0` and `source: "fallback"`.
- AC-08.4: `LlmProvider` has no method signature that accepts or returns ActiveRecord objects, order mutations, or financial operation parameters.
- AC-08.5: Every AI invocation produces an audit record with: `llm_model`, `llm_call_id`, input context summary (truncated), and the full structured output.
- AC-08.6: Every proposed action in AI output includes `confidence`, `reasoning`, and `evidence` array.
- AC-08.7: `LlmProviders::FakeProvider` returns pre-configured responses keyed by failure type, with no network calls, for use in tests and scripted demos.

---

### REQ-09 — Deterministic Policy and Guardrail Engine

#### Description
`PolicyEngine` is the sole decision authority for whether a recovery action may execute. It is a pure Ruby service: no ActiveRecord, no I/O. It evaluates actions in the fixed pipeline order defined in ADR-13.

#### Evaluation Pipeline (order is enforced)
1. **Hard safety rules** (allergen/dietary constraints from `customer_recovery_preferences` if present)
2. **Customer constraints** (expressed recovery preferences)
3. **Guardrail rules** (the six rules below)
4. **Policy rules** (from `orderops_policy.yml`)
5. **Operational score** (tiebreaker when multiple actions are approved)

#### Guardrail Rules (stage 3 — always enforced)
1. A refund may not exceed `order.order_total`.
2. `FULL_REFUND` cannot execute if the order is in `in_delivery` or `delivered` state.
3. `REROUTE_RESTAURANT` cannot be attempted if `order.reroute_attempt_count >= policy.reroute_limit`.
4. No action may execute on an order in a terminal state (`delivered`, `cancelled`, `recovered`).
5. `CANCEL_ORDER` requires human approval unless the policy defines an automatic condition that is met.
6. An action whose idempotency key already exists in `recovery_actions` with status `completed` is denied as a duplicate.

#### Acceptance Criteria
- AC-09.1: `PolicyEngine.evaluate` applies all five pipeline stages in order; an action denied at stage N is not evaluated at stage N+1.
- AC-09.2: A denied action returns `PolicyDecision` with `approved: false` and `reason` citing the specific rule violated.
- AC-09.3: Stage 3 guardrail rules are applied before stage 4 configurable policy rules.
- AC-09.4: `PolicyEngine` takes no database connections, HTTP clients, or external I/O as dependencies.
- AC-09.5: `PolicyEngine` has a dedicated RSpec unit test file with 100% branch coverage of all guardrail rules.
- AC-09.6: Every evaluation (approved and denied) produces an audit record with the pipeline stage that determined the outcome and the `policy_version`.

---

### REQ-10 — Human Approval for High-Risk Actions

#### Description
High-risk recovery actions are queued in the `approval_queue` database table and surfaced in the dashboard via Turbo Streams. Execution is blocked until an operator approves or rejects.

#### High-Risk Action Triggers (any condition triggers approval requirement)
- `FULL_REFUND` and `order.order_total > policy.full_refund_approval_threshold`
- `CANCEL_ORDER` and order state is `preparing`, `ready_for_pickup`, `in_delivery`, or later
- `order.reroute_attempt_count >= policy.reroute_approval_threshold` (default: 2)
- AI top-ranked action `confidence < policy.min_confidence_threshold` (default: 0.5)
- Action type is explicitly listed under `approval_required` in `orderops_policy.yml`

#### Approval Workflow
1. `PolicyEngine` returns `approved: true, requires_human_approval: true`
2. `RecoveryOrchestrator` creates an `ApprovalQueue` record; order → `pending_approval`
3. `approval.requested` event published → Turbo Stream updates dashboard approval panel
4. Operator approves or rejects via Rails form (PATCH `/approval_queue/:id`)
5. `approval.received` event published; `RecoveryOrchestrator` resumes
6. Approval SLA timer: if no decision within `policy.approval_timeout_seconds` (default: 120), escalation event emitted

#### Auto-approve mode (test/demo only)
When `config/orderops.yml` sets `approvals.mode: auto_approve`, `ApprovalWorker` automatically approves after `auto_approve_delay_seconds`. Startup raises if `RAILS_ENV` is `production` or `staging`.

#### Acceptance Criteria
- AC-10.1: Any high-risk action (per the five triggers above) creates an `ApprovalQueue` record before any execution occurs.
- AC-10.2: The dashboard approval panel shows: order ID, failure type, AI diagnosis summary, proposed action, confidence score, elapsed wait time — updated in real-time via Turbo Streams.
- AC-10.3: PATCH `/approval_queue/:id` with `{decision: approved|rejected, note: string}` processes the decision.
- AC-10.4: If the approval timeout expires, an escalation event is emitted; a configurable safe fallback action is executed if defined in policy.
- AC-10.5: Approval decisions are recorded in the audit trail with `actor: "human:{operator_id}"`, timestamp, and note.
- AC-10.6: Submitting a second approval decision for an already-decided `ApprovalQueue` record returns a 422 response.
- AC-10.7: `auto_approve` mode raises `ApprovalConfiguration::InvalidEnvironment` at startup in `production`/`staging`.

---

### REQ-11 — Complete Audit Trail

#### Description
The `AuditTrail` service is an event bus subscriber. It writes an `audit_records` PostgreSQL row for every domain event and for every explicit execution boundary recorded by `ActionExecutor`. Records are append-only.

#### `audit_records` Table Schema
| Column | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `order_id` | UUID | Indexed |
| `sequence_number` | integer | Per-order monotonic counter |
| `occurred_at` | timestamp | UTC, millisecond precision |
| `event_type` | string | |
| `subsystem` | string | |
| `actor` | string | `system` / `ai_agent` / `human:{id}` / `simulator` |
| `state_before` | string | Nullable |
| `state_after` | string | Nullable |
| `payload` | jsonb | No customer PII in AI-authored fields |
| `policy_version` | string | Nullable |
| `llm_model` | string | Nullable |
| `llm_call_id` | string | Nullable |
| `idempotency_key` | string | Nullable |
| `injected` | boolean | Default false |

Append-only enforcement: a PostgreSQL trigger raises an exception on any `UPDATE` or `DELETE` against `audit_records`.

#### Acceptance Criteria
- AC-11.1: Every order state transition produces an audit record with `state_before` and `state_after`.
- AC-11.2: Every policy evaluation (approved or denied) produces an audit record with `policy_version` and the pipeline stage that decided the outcome.
- AC-11.3: Every AI invocation produces an audit record with `llm_model`, `llm_call_id`, input context summary, and the full structured AI output.
- AC-11.4: Every human approval request and decision produces an audit record with `actor: "human:{operator_id}"`.
- AC-11.5: No `UPDATE` or `DELETE` SQL is ever issued against `audit_records` in application code; the PostgreSQL trigger provides a second enforcement layer.
- AC-11.6: `AuditTrail.for_order(order_id)` returns all records for an order in `sequence_number` ascending order.
- AC-11.7: The audit timeline dashboard panel renders the complete event history for an order on demand.

---

### REQ-12 — Operational Observability

#### Description
The operational dashboard is a Rails application served at `/dashboard`. All real-time updates use Hotwire Turbo Streams over Action Cable backed by **Solid Cable** — the Rails 8.1 default database-backed Action Cable adapter. No Redis is required. No separate SPA is built.

#### Dashboard Panels
1. **Order Stream** (`turbo-frame id="order-stream"`) — live list: order ID, state, SLA phase, SLA colour (green/amber/red)
2. **Failure Feed** (`turbo-frame id="failure-feed"`) — real-time: failure type, order ID, elapsed since failure
3. **Recovery Queue** (`turbo-frame id="recovery-queue"`) — active recoveries: AI diagnosis summary, proposed action, status
4. **Approval Queue** (`turbo-frame id="approval-queue"`) — pending approvals with approve/reject buttons
5. **System Metrics** (`turbo-frame id="metrics"`) — aggregate counters refreshed on each relevant event
6. **Audit Timeline** (`/dashboard/orders/:id/audit`) — full chronological audit trail for one order

#### Acceptance Criteria
- AC-12.1: All six panels are rendered by Rails ERB views; Turbo Stream broadcasts push updates without a page reload.
- AC-12.2: Each active order in the Order Stream shows current state and SLA colour (green: within warning threshold; amber: at warning; red: breached).
- AC-12.3: New failure events appear in the Failure Feed within one Sidekiq processing cycle of the failure event being published.
- AC-12.4: The Recovery Queue shows the AI diagnosis summary and proposed action for each in-progress recovery.
- AC-12.5: The Approval Queue renders approve/reject form buttons that submit to `PATCH /approval_queue/:id`.
- AC-12.6: System Metrics display: total active orders, orders in SLA warning, orders in SLA breached, recovery success count, recovery failure count.
- AC-12.7: The Audit Timeline at `/dashboard/orders/:id/audit` renders all audit records for the order in chronological sequence.

---

## Non-Functional Requirements

### NFR-01 — Simulation Fidelity
- All external integrations (restaurant, inventory, payment, delivery) are implemented as Ruby service objects conforming to defined interfaces in `app/interfaces/`.
- Simulators support configurable latency (via `sleep` with jitter), failure probability, and capacity limits — all set in `config/orderops.yml`.
- Simulators support deterministic failure injection via the `FailureInjector` API (REQ-05).

### NFR-02 — Testability
- Each subsystem (`OrderStateMachine`, `EventBus`, `SlaMonitor`, `RestaurantRouter`, `PolicyEngine`, `LlmAgent`, `RecoveryOrchestrator`, `AuditTrail`) has a dedicated RSpec unit spec.
- Integration specs cover the primary demo scenario end-to-end using `FakeProvider` and `SynchronousEventBusAdapter`.
- `PolicyEngine` unit specs achieve 100% branch coverage of all six guardrail rules and all five pipeline stages.
- `FactoryBot` factories exist for all domain models.

### NFR-03 — Configurability
- All SLA thresholds, policy limits, high-risk action thresholds, simulation parameters, LLM provider, and approval mode are read from `config/orderops.yml` and `config/orderops_policy.yml` at startup.
- No business rule value is hard-coded as a Ruby literal.
- A missing required configuration key raises a descriptive error at startup, not at runtime.

### NFR-04 — Extensibility
- Adding a new failure type requires changes to: (1) the failure type constant file, (2) `config/orderops_policy.yml`, (3) the `FailureDetector` handler. No other files require modification.
- Adding a new recovery action type requires changes to: (1) the action type constant file, (2) `config/orderops_policy.yml`, (3) `ActionExecutor`. No other files require modification.
- Adding a new LLM provider requires creating one new class in `app/services/llm_providers/` implementing `LlmProviders::Base`.

### NFR-05 — AI Boundary Enforcement
- `LlmProvider` implementations are restricted to a single public method: `complete(prompt: String) → String`.
- `LlmAgent` constructs a read-only context struct (`LlmContext`) that excludes ActiveRecord objects and customer PII beyond opaque IDs.
- Code review checklist item: no `LlmProvider` subclass may `require` or reference `OrderStateMachine`, `ActionExecutor`, `PolicyEngine`, any simulator class, or any ActiveRecord model.

### NFR-06 — Idempotency
- Every recovery action execution is guarded by an idempotency key in the `recovery_actions` table.
- A `UNIQUE` constraint on `recovery_actions.idempotency_key` is enforced at the database level.
- `ActionExecutor` handles `ActiveRecord::RecordNotUnique` (duplicate key) by reading the existing record's status rather than raising an unhandled error.

### NFR-07 — Rails 8.1 Conventions
- The application follows standard Rails 8.1 directory structure: models in `app/models/`, services in `app/services/`, jobs in `app/jobs/`, views in `app/views/`.
- Domain service objects (not ActiveRecord models) live in `app/services/` and are named as `VerbNoun` (e.g., `RecoveryOrchestrator`, `PolicyEngine`, `LlmAgent`).
- Background jobs (ActiveJob subclasses) live in `app/jobs/`. Jobs that span multiple logical steps use `ActiveJob::Continuable`.
- Interface definitions (Ruby modules with documented method signatures) live in `app/interfaces/`.
- The asset pipeline uses **Propshaft** (Rails 8.1 default). JavaScript is managed via importmap. No Node.js build step is required.
- Background job processing uses **Solid Queue** (Rails 8.1 default; configured in `config/queue.yml`).
- Action Cable uses **Solid Cable** (Rails 8.1 default; configured in `config/cable.yml`).
- **No Redis instance is required.** PostgreSQL is the sole database service for application state, background jobs, Action Cable, and audit trail.

### NFR-08 — Infrastructure Simplicity
- The complete OrderOps platform runs with a single `docker compose up` command that starts only: a PostgreSQL container and a Rails server container (which hosts the web process, Solid Queue worker, and Solid Cable relay).
- No Redis, no Kafka, no separate Sidekiq process is required.
