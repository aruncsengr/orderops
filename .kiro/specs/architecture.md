# OrderOps — Architectural Decisions

**Version:** 0.3  
**Status:** All open questions resolved. Ready for implementation.

---

## Resolved Architectural Decisions

### ADR-01 — AI Is Advisory Only; Policy Engine Is the Decision Authority

**Status:** Accepted  
**Resolves:** Original design principle, reinforced by Additional Requirement 1 and 3

**Context:**
The system deals with refunds, cancellations, and financial compensation. Allowing an LLM to directly execute these operations introduces unacceptable risks: hallucinated actions, inconsistent policy application, and auditability gaps.

**Decision:**
The LLM agent may only read order context and propose recovery actions from a fixed, pre-defined list. The policy engine independently validates every proposed action after the AI recommendation and before any execution. Application services execute approved actions. No execution path exists that bypasses the policy engine.

The evaluation order is fixed and non-negotiable:
1. AI recommendation (read-only context, proposes actions)
2. Policy evaluation (approves or denies each proposed action)
3. Execution (only if policy approved)

**Consequences:**
- The system is more complex (three layers instead of one), but far safer.
- The AI can be swapped or upgraded without changing execution or policy logic.
- Every decision is auditable because the policy engine produces a structured decision record.
- The AI cannot invent novel actions; it can only rank and reason about the defined action types.

---

### ADR-02 — Simulated Integrations for V1

**Status:** Accepted

**Context:**
Real restaurant, payment, inventory, and delivery APIs introduce external dependencies, rate limits, costs, and unreliable test conditions. For the Kiro University challenge demo, we need full control over failure scenarios.

**Decision:**
All external integrations (restaurant, inventory, payment, delivery) are in-process Ruby objects implementing a defined interface contract. The rest of the system depends only on the interface, not the simulator implementation. Replacing a simulator with a real integration in a future version is a matter of swapping the implementation class, not redesigning the system.

**Consequences:**
- We can demonstrate any failure scenario deterministically.
- Simulator latency and failure rates are configurable via Rails credentials / environment config.

---

### ADR-03 — Event-Driven Internal Architecture with Abstract Event Interface

**Status:** Accepted  
**Resolves:** OQ-03, Additional Requirement 9

**Context:**
The order lifecycle involves multiple subsystems. Direct method calls between them create tight coupling. Introducing an external broker (Kafka, RabbitMQ) adds operational complexity not warranted for V1.

**Decision:**
All subsystems communicate through a typed internal event bus abstraction. In V1, the concrete implementation dispatches events via **Solid Queue** — the Rails 8 default database-backed ActiveJob adapter, which uses PostgreSQL with `FOR UPDATE SKIP LOCKED` and requires no Redis. The event bus interface is defined as a Ruby module so a real broker (Kafka, Redis Streams) can be substituted later by swapping the adapter, not the callers.

Domain events carry a per-order sequence number. Consumers implement deduplication using event IDs stored in the database. The database (PostgreSQL) is the source of truth; the event bus is a delivery mechanism, not the record of truth.

**Interface contract:**
```
EventBus.publish(event)           # publishes a domain event
EventBus.subscribe(type, handler) # registers a handler
```

The adapter behind `EventBus` is injected at startup (`ActiveJobEventBusAdapter` in V1). A `SynchronousEventBusAdapter` is available for tests to avoid background job overhead.

**Consequences:**
- Any new subsystem can subscribe to events without touching existing code.
- The audit trail records all events passively as a subscriber.
- Event storms are prevented by checking current order state before acting (consumer-side guard).
- Per-order sequence numbers allow consumers to detect gaps and out-of-order delivery.
- No Redis process is required to run OrderOps — PostgreSQL is the only database service.
- **No external message broker in V1.** Events are delivered via ActiveJob backed by Solid Queue (PostgreSQL). The event bus interface abstracts this so a real broker can be substituted later by swapping the adapter.

---

### ADR-04 — State Machine Is the Authoritative Order State, with Optimistic Concurrency

**Status:** Accepted  
**Resolves:** OQ-01

**Context:**
Multiple subsystems (background jobs, SLA monitor, recovery orchestrator) may attempt to transition the same order's state concurrently. Without a concurrency control mechanism, race conditions produce corrupted state.

**Decision:**
The `Order` ActiveRecord model carries an integer `lock_version` column. Rails optimistic locking (`lock_version`) is used for all state transitions. A transition attempt that encounters a stale version raises `ActiveRecord::StaleObjectError`, which the caller must handle by reloading and retrying or abandoning.

All state transitions go through the `OrderStateMachine` service. No code sets `order.state` directly outside that service. The service validates the transition, updates the state and version atomically, and publishes a domain event.

**Consequences:**
- State integrity is guaranteed without database-level row locks.
- Background jobs that race on the same order fail cleanly and can retry via ActiveJob retry semantics.
- The state machine must be tested exhaustively for all valid, invalid, and concurrent transition scenarios.

---

### ADR-05 — Technology Stack: Ruby 3.4.5 + Rails 8.1.4 + PostgreSQL + Solid Queue + Solid Cable + Hotwire

**Status:** Accepted  
**Resolves:** OQ-02, OQ-06, OQ-07

**Stack:**
| Layer | Technology | Notes |
|---|---|---|
| Runtime | Ruby 3.4.5 | Pinned in `.ruby-version` |
| Application framework | Ruby on Rails 8.1.4 | |
| Primary database | PostgreSQL | |
| Background jobs | ActiveJob + **Solid Queue** | Rails 8 default; database-backed; no Redis required |
| Action Cable / WebSockets | **Solid Cable** | Rails 8 default; database-backed; no Redis required |
| Dashboard UI | Rails views + Hotwire (Turbo Streams + Stimulus) | |
| Asset pipeline | **Propshaft** | Rails 8 default; replaces Sprockets |
| Audit trail persistence | PostgreSQL (`audit_records` table) | |
| Policy configuration | YAML files loaded via Rails initializer | |
| Test framework | RSpec + FactoryBot + SimpleCov | |
| Job continuations | ActiveJob::Continuable | Rails 8.1 feature; used by `RecoveryOrchestratorJob` |

**Rationale:**
- Ruby 3.4.5 is the installed runtime. Pinned in `.ruby-version` for reproducibility.
- Rails 8.1.4 is the current stable release. Solid Queue and Solid Cable ship as production defaults.
- Solid Queue uses PostgreSQL's `FOR UPDATE SKIP LOCKED` — the same database already required for order state. No additional infrastructure.
- Solid Cable stores WebSocket messages in the database; message retention (default: 1 day) is sufficient for the dashboard's real-time update pattern.
- Propshaft replaces Sprockets; importmap manages JavaScript with no Node.js build step.
- Active Job Continuations allow `RecoveryOrchestratorJob` to checkpoint across steps (AI call → policy evaluation → execution), surviving restarts without re-running completed steps.
- No Kafka, no Redis, no Sidekiq in V1. PostgreSQL is the only required database service.

---

### ADR-06 — Policy Configuration Externalised from Code

**Status:** Accepted  
**Resolves:** Original design principle

**Decision:**
All policy parameters (refund thresholds, compensation limits, re-routing limits, approval triggers, failure-type-to-action mappings) are defined in `config/orderops_policy.yml`. The policy engine (`PolicyEngine` service) loads this file at startup via a Rails initializer and exposes a pure evaluation interface. The YAML file has a `version` string field; this version is recorded in every audit record produced by a policy evaluation.

Policy changes require a server restart in V1. Live reload is a future enhancement.

**Consequences:**
- Policies can be reviewed by non-engineers.
- Policy version is auditable in the database.
- The policy engine is a pure function over order state + policy config — zero I/O — making it trivially unit-testable.

---

### ADR-07 — Failure Injection Is a First-Class Feature, Gated by Environment

**Status:** Accepted  
**Resolves:** OQ-08 (deterministic demo), Additional Requirement 8

**Decision:**
The `FailureInjector` is a first-class service with a formal API. It injects failures by publishing domain events through the same event bus used by real failures. Injected failure events carry `injected: true` in their payload, which is stored in the audit trail.

The `FailureInjector` is only accessible in `development` and `demo` Rails environments. It is explicitly excluded from the `production` environment via a Rails environment check. The demo environment is a named Rails environment (`RAILS_ENV=demo`) distinct from test.

**Consequences:**
- The demo scenario is fully scripted and repeatable.
- Injected vs. natural failures are distinguishable in the audit trail.
- No injection surface exists in production.

---

### ADR-08 — Deterministic Fallback for AI Failure

**Status:** Accepted  
**Resolves:** OQ-04 (single call confirmed), ADR-06 original

**Decision:**
The AI agent is invoked via a single LLM call per recovery event in V1. Multi-agent chains are not implemented.

The `LlmAgentInterface` wraps the call in a timeout boundary (configurable, default 15 s). If the call fails, times out, or returns output that fails schema validation, the interface activates the deterministic fallback strategy:

1. Look up the failure type in `config/orderops_policy.yml` under `fallback_recovery`
2. Return the configured fallback action(s) with `confidence: 0.0` and `source: "fallback"`
3. Record the fallback reason in the audit trail

The fallback must be defined for every failure type. A missing fallback entry is a startup-time configuration error, not a runtime error.

**Consequences:**
- System availability does not depend on LLM availability.
- Fallback decisions are clearly labelled in the audit trail.
- The single-call interface can be swapped to a multi-call chain later without changing the policy engine or orchestrator.

---

### ADR-09 — Provider-Independent LLM Interface with Fake Provider for Tests

**Status:** Accepted  
**Resolves:** OQ-05

**Decision:**
The `LlmProvider` is an injected dependency conforming to a Ruby interface (module with defined method signatures). V1 ships with two concrete providers:

| Provider | Class | Use |
|---|---|---|
| OpenAI-compatible | `LlmProviders::OpenAiProvider` | Production and demo (default) |
| Deterministic fake | `LlmProviders::FakeProvider` | Unit tests and scripted demos |

The `FakeProvider` returns configurable pre-canned responses keyed by failure type, making tests and demos fully deterministic without any LLM calls.

The provider is configured via `config/orderops.yml`:
```yaml
llm:
  provider: openai   # or: fake
  model: gpt-4o-mini
  timeout_seconds: 15
```

A future `BedrockProvider` or `OllamaProvider` can be added by implementing the `LlmProviders::Base` interface without touching the agent, orchestrator, or any other component.

**AI output schema validation:**
All LLM responses are parsed and validated against a strict JSON schema (Additional Requirement 2) before being passed to the policy engine. A response that fails schema validation is treated identically to a provider failure — the fallback strategy (ADR-08) activates.

---

### ADR-10 — Recovery Actions Use Idempotency Keys Backed by Database Uniqueness

**Status:** Accepted  
**Resolves:** OQ-08, Additional Requirement 7

**Decision:**
Every recovery action execution generates an idempotency key composed of `order_id + action_type + attempt_number`. This key is stored in a `recovery_actions` table with a `UNIQUE` constraint on the idempotency key column.

Before executing any state-changing or financial operation, the `ActionExecutor` inserts a `recovery_actions` record with status `pending`. If a duplicate key error occurs, the action has already been attempted; the executor reads the existing record's status and behaves accordingly (returns the existing result, or escalates if the previous attempt is stuck in `pending`).

On completion, the record is updated to `completed` (success) or `failed`. This covers:
- Duplicate ActiveJob execution (job enqueued twice, retry after crash)
- Concurrent recovery attempts triggered by multiple events

**Consequences:**
- Financial operations (refunds, vouchers) are safe against duplicate execution.
- The `recovery_actions` table serves as both an idempotency store and an execution log.
- The `recovery_actions` table feeds the recovery queue in the dashboard.

---

### ADR-11 — Human Approval Is Default; Auto-Approve Is Environment-Gated

**Status:** Accepted  
**Resolves:** OQ-09

**Decision:**
Human approval is required for all high-risk actions in production-like mode. An auto-approve mode is available for automated tests and the scripted demo environment, configured via:

```yaml
# config/orderops.yml
approvals:
  mode: manual        # manual | auto_approve
  auto_approve_delay_seconds: 2   # only used in auto_approve mode
```

The `auto_approve` mode is only permitted when `RAILS_ENV` is `test` or `demo`. An attempt to configure `auto_approve` in `production` or `staging` raises a startup error.

In `manual` mode, the approval flow is:
1. `ApprovalQueue` record created, order moved to `PENDING_APPROVAL`
2. Turbo Stream broadcast updates the dashboard approval queue panel in real-time
3. Operator approves or rejects via a Rails form action
4. Decision is persisted and the recovery orchestrator background job is resumed

**Consequences:**
- Production safety is guaranteed by configuration validation at startup.
- The demo can run with `auto_approve` for a fully scripted, uninterrupted flow, or with `manual` for a live human-in-the-loop demonstration.

---

### ADR-12 — V1 Order Data Model

**Status:** Accepted  
**Resolves:** OQ-10

**Order aggregate fields (PostgreSQL `orders` table):**
| Column | Type | Notes |
|---|---|---|
| `id` | UUID | Primary key |
| `customer_id` | UUID | References customers table |
| `restaurant_id` | UUID | Nullable; set on assignment |
| `state` | string | Enum: current state machine state |
| `lock_version` | integer | Optimistic concurrency (Rails default) |
| `items` | jsonb | Array of `{name, quantity, unit_price, currency}` |
| `order_total` | decimal(10,2) | Pre-computed sum |
| `currency` | string(3) | ISO 4217, e.g. "USD" |
| `delivery_address` | jsonb | `{street, city, postcode, lat, lng}` |
| `payment_intent_id` | string | Simulator payment intent reference |
| `sla_started_at` | timestamp | When current SLA phase began |
| `sla_phase` | string | Current SLA phase name |
| `customer_recovery_preferences` | jsonb | `{preferred_action, contact_method}` — nullable |
| `cuisine_type` | string | Used for routing |
| `rejected_restaurant_ids` | uuid[] | Restaurants that have rejected this order |
| `reroute_attempt_count` | integer | Default 0; used by guardrail OQ-01 |
| `created_at` | timestamp | |
| `updated_at` | timestamp | |

**Note on `customer_recovery_preferences`:** Stored on the order (not just the customer) so the preference at order time is preserved in the audit trail even if the customer's profile changes later.

---

### ADR-13 — Safety and Customer Constraints Evaluated Before Operational Optimisation

**Status:** Accepted  
**Resolves:** Additional Requirement 4

**Decision:**
The policy engine evaluation pipeline enforces a fixed evaluation order:

1. **Hard safety rules** — actions that would cause physical harm or violate consumer protection law are denied regardless of all other factors. (In V1: allergen/dietary constraints from `customer_recovery_preferences` are checked here if present.)
2. **Customer constraints** — customer's expressed recovery preferences are evaluated. A customer who has opted out of re-routing cannot be re-routed even if operationally optimal.
3. **Guardrail rules** — the six fixed business guardrails (ADR-01 / REQ-09).
4. **Policy rules** — configurable refund/compensation policies from `orderops_policy.yml`.
5. **Operational optimisation** — if multiple actions pass all above checks, the policy engine selects the one with the best operational score (lowest cost, fastest resolution).

An action that fails stage 1 or 2 is DENIED even if it would pass stages 3–5. This evaluation order is enforced structurally in the `PolicyEngine` class, not just by convention.

---

### ADR-14 — Structured Reasoning Required in Every AI Recommendation

**Status:** Accepted  
**Resolves:** Additional Requirement 5

**Decision:**
The LLM prompt instructs the AI to return a structured JSON response. The required schema for every proposed recovery action includes:

```json
{
  "action_type": "REROUTE_RESTAURANT",
  "confidence": 0.85,
  "reasoning": "The kitchen reported a hard failure with no ETA. Re-routing to a nearby restaurant with available capacity minimises customer wait time.",
  "evidence": [
    "failure_type: KITCHEN_FAILURE",
    "reroute_attempt_count: 0",
    "available_restaurants: 3"
  ],
  "estimated_customer_impact": "MEDIUM"
}
```

The `evidence` array is a list of factual observations from the order context that support the recommendation. It must not contain customer PII.

The `LlmAgentInterface` validates this schema using a JSON Schema validator before passing proposals to the policy engine. Proposals that fail validation are discarded; if all proposals are invalid, the fallback strategy (ADR-08) activates.

**Consequences:**
- AI reasoning is auditable — the `evidence` array is stored in the audit trail.
- The dashboard can display why the AI made a recommendation, not just what it recommended.
- Schema validation acts as a guardrail against prompt injection attempts that try to produce malformed output.

---

### ADR-15 — Every State-Changing Action Is Auditable

**Status:** Accepted  
**Resolves:** Additional Requirement 6

**Decision:**
The `AuditTrail` service is a subscriber to all domain events on the event bus. It writes an `audit_records` row for every event. The `ActionExecutor` additionally writes explicit "execution started" and "execution completed" (or "execution failed") audit records around every state-changing or financial operation.

The `audit_records` PostgreSQL table is append-only by convention and enforced by:
- No `UPDATE` or `DELETE` is ever issued against this table in application code.
- A PostgreSQL `RULE` or `TRIGGER` that raises an error on `UPDATE`/`DELETE` is applied as a defence-in-depth measure.

**Audit record schema (PostgreSQL `audit_records` table):**
| Column | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `order_id` | UUID | |
| `sequence_number` | integer | Per-order sequence, monotonically increasing |
| `occurred_at` | timestamp | UTC, millisecond precision |
| `event_type` | string | |
| `subsystem` | string | Originating subsystem |
| `actor` | string | system / ai_agent / human:{operator_id} / simulator |
| `state_before` | string | Nullable |
| `state_after` | string | Nullable |
| `payload` | jsonb | Event-specific data (no PII in AI-authored fields) |
| `policy_version` | string | Nullable; set when a policy evaluation occurred |
| `llm_model` | string | Nullable; set for AI invocations |
| `llm_call_id` | string | Nullable; set for AI invocations |
| `idempotency_key` | string | Nullable; set for executed recovery actions |
| `injected` | boolean | True if failure was artificially injected |

---

## Resolved Questions Summary

All 10 original open questions are now resolved:

| OQ | Question | Resolution |
|---|---|---|
| OQ-01 | Concurrency model | ADR-04: Optimistic concurrency via Rails `lock_version` |
| OQ-02 | Technology stack | ADR-05: Ruby 3.4.5 + Rails 8.1.4 + PostgreSQL + Solid Queue + Solid Cable + Hotwire |
| OQ-03 | Event bus ordering | ADR-03: Per-order sequence numbers + consumer-side dedup |
| OQ-04 | AI agent architecture | ADR-08: Single LLM call per recovery event in V1 |
| OQ-05 | LLM provider | ADR-09: OpenAI-compatible default; fake provider for tests; abstract interface for future providers |
| OQ-06 | Audit trail persistence | ADR-05 / ADR-15: PostgreSQL `audit_records` table |
| OQ-07 | Dashboard technology | ADR-05: Rails views + Hotwire Turbo Streams; no SPA |
| OQ-08 | Recovery action idempotency | ADR-10: Idempotency keys with PostgreSQL uniqueness constraints |
| OQ-09 | Human approval mode | ADR-11: Manual default; auto-approve in `test`/`demo` environments only |
| OQ-10 | V1 order data model | ADR-12: Full field list defined |

---

## Resolved Ambiguities

| # | Ambiguity | Resolution |
|---|---|---|
| A1 | "AI-assisted" — does this mean the AI executes or advises? | ADR-01: AI is strictly advisory. Policy engine decides. Application services execute. |
| A2 | "Simulated restaurants" — single simulator or per-restaurant? | Each simulated restaurant is a separate Ruby object with its own state, capacity, and failure probability. |
| A3 | "Human approval for high-risk actions" — who is the human in the demo? | ADR-11: Presenter by default (manual mode); auto-approve available in `demo` environment. |
| A4 | "Recovery orchestration" — synchronous or async? | ADR-03: Async via Solid Queue (ActiveJob); orchestrator reacts to events and enqueues new jobs. `ActiveJob::Continuable` used for multi-step recovery jobs (Rails 8.1). |
| A5 | "Complete audit trail" — in-memory for demo or persistent? | ADR-15: PostgreSQL `audit_records` table, append-only. |
| A6 | "Operational observability" — what does V1 need to show? | REQ-12: Six panels via Rails + Hotwire Turbo Streams. |
| A7 | "Customer recovery preferences" — in scope for V1? | ADR-12: Stored on the order model as a nullable jsonb field. Evaluated in stage 2 of policy pipeline (ADR-13). |
