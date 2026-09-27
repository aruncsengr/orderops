# OrderOps — Kiro Specification

**Project:** OrderOps  
**Challenge:** Kiro University  
**Version:** 0.2  
**Status:** All architectural decisions resolved. Ready for implementation.

**Stack:** Ruby on Rails · PostgreSQL · Redis/Sidekiq · Hotwire (Turbo Streams + Stimulus)

---

## 1. What We Are Building

OrderOps is an AI-powered Order Reliability and Recovery Platform for food ordering systems. It solves a specific, high-value problem: orders can fail or become at risk *after* they have been placed, and existing systems have no structured way to detect, diagnose, and recover from those failures automatically.

OrderOps monitors every order through its lifecycle, detects failure conditions and SLA breaches, invokes an AI agent to diagnose the problem and propose recovery actions, validates those proposals through a deterministic policy engine, executes approved actions, and records everything in a complete audit trail — all persisted in PostgreSQL and surfaced through a live Hotwire dashboard.

---

## 2. The Core Problem

A food order can fail in many ways after placement:

- A restaurant rejects or stops responding
- An ingredient is unavailable (inventory failure)
- The kitchen is overloaded (delay) or fails (hard failure)
- A delivery courier fails or is delayed past acceptable SLA
- Payment processing fails or needs retry
- An external service becomes unavailable

Each failure type has different recovery options with different risk levels, costs, and customer impacts. Without a structured system, operators make ad-hoc decisions, recovery is inconsistent, and nothing is auditable.

---

## 3. Core Architectural Principles

```
AI reasons and recommends.
Deterministic policies decide what is allowed.
Application services execute approved actions.
```

**The fixed pipeline — no step may be skipped or reordered:**

```
AI recommendation → Policy evaluation → [Human approval if high-risk] → Execution
```

An LLM must never directly call mutation functions, issue refunds, cancel orders, or change order state. This is enforced structurally: `LlmProvider` has no method signatures that accept or return domain objects with mutation capability.

**Safety evaluation order within policy (ADR-13):**
```
Hard safety rules → Customer constraints → Guardrail rules → Policy rules → Operational optimisation
```

An action that fails an earlier stage is denied without evaluating later stages.

---

## 4. System Capabilities (V1 Scope)

| # | Capability | Spec Reference |
|---|---|---|
| 1 | Order lifecycle and state management | REQ-01 |
| 2 | Event-driven order monitoring | REQ-02 |
| 3 | SLA monitoring and breach detection | REQ-03 |
| 4 | Restaurant routing and re-routing | REQ-04 |
| 5 | Failure detection and injection | REQ-05 |
| 6 | Recovery orchestration | REQ-06 |
| 7 | Refund and compensation policy management | REQ-07 |
| 8 | AI-assisted failure diagnosis and recovery planning | REQ-08 |
| 9 | Deterministic policy and guardrail engine | REQ-09 |
| 10 | Human approval for high-risk actions | REQ-10 |
| 11 | Complete audit trail | REQ-11 |
| 12 | Operational observability (dashboard) | REQ-12 |

Full requirements and acceptance criteria: [requirements.md](requirements.md)  
Architectural decisions: [architecture.md](architecture.md)

---

## 5. Architecture Overview

### Technology Stack

| Layer | Technology | Notes |
|---|---|---|
| Application | Ruby on Rails | Convention-over-configuration; standard MVC structure |
| Database | PostgreSQL | Orders, audit trail, idempotency keys, approval queue |
| Background jobs | ActiveJob + Sidekiq + Redis | Async event dispatch, SLA monitor, recovery orchestration |
| Real-time UI | Hotwire (Turbo Streams + Stimulus) | Dashboard live updates via Action Cable / Redis |
| LLM provider | OpenAI-compatible (default) | Abstract `LlmProviders::Base` interface; fake provider for tests |
| Policy config | YAML (`config/orderops_policy.yml`) | Loaded at startup; version tracked in audit trail |
| Test framework | RSpec + FactoryBot | |
| Event bus (V1) | `ActiveJobEventBusAdapter` | Abstract `EventBus` interface; replaceable with Kafka/Redis Streams later |

### Rails Application Layout

```
app/
├── models/           # ActiveRecord: Order, AuditRecord, RecoveryAction, ApprovalQueue
├── services/
│   ├── order_state_machine.rb
│   ├── sla_monitor.rb
│   ├── failure_detector.rb
│   ├── failure_injector.rb
│   ├── restaurant_router.rb
│   ├── policy_engine.rb
│   ├── llm_agent.rb
│   ├── recovery_orchestrator.rb
│   ├── action_executor.rb
│   ├── audit_trail.rb
│   ├── event_bus.rb
│   └── llm_providers/
│       ├── base.rb
│       ├── open_ai_provider.rb
│       └── fake_provider.rb
├── jobs/
│   ├── sla_monitor_job.rb
│   ├── recovery_orchestrator_job.rb
│   └── approval_timeout_job.rb
├── interfaces/
│   ├── restaurant_simulator_interface.rb
│   ├── payment_simulator_interface.rb
│   ├── inventory_simulator_interface.rb
│   └── delivery_simulator_interface.rb
├── simulators/
│   ├── restaurant_simulator.rb
│   ├── payment_simulator.rb
│   ├── inventory_simulator.rb
│   └── delivery_simulator.rb
├── controllers/
│   └── dashboard/
│       ├── orders_controller.rb
│       ├── approval_queue_controller.rb
│       └── audit_controller.rb
└── views/
    └── dashboard/
        ├── index.html.erb        # Main dashboard with all panels
        ├── orders/               # Order stream, audit timeline
        └── approval_queue/       # Approval form
config/
├── orderops.yml                  # LLM provider, timeouts, approval mode, simulation params
└── orderops_policy.yml           # Policy version, refund rules, guardrails, fallback actions
```

### Subsystem Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        OrderOps (Rails Application)                  │
│                                                                       │
│  ┌──────────────────┐   ┌─────────────────────┐                     │
│  │ OrderStateMachine│   │ EventBus             │                     │
│  │ (PostgreSQL +    │◄──│ (ActiveJobAdapter    │                     │
│  │  lock_version)   │   │  backed by Redis)    │                     │
│  └────────┬─────────┘   └──────────┬──────────┘                     │
│           │                         │                                 │
│    ┌──────▼──────┐          ┌───────▼──────────┐                    │
│    │ AuditTrail  │          │  SlaMonitor       │                    │
│    │ (PostgreSQL │◄─────────│  (Sidekiq cron,   │                    │
│    │  append-    │          │   configurable    │                    │
│    │  only)      │          │   tick interval)  │                    │
│    └─────────────┘          └───────┬──────────┘                    │
│                                     │ sla.warning / sla.breached     │
│    ┌────────────────────────────────▼──────────────────────┐        │
│    │              RecoveryOrchestrator (ActiveJob)          │        │
│    │                                                        │        │
│    │  1. LlmAgent.diagnose(context) ──────────────────────►│        │
│    │     └─► LlmProviders::OpenAiProvider (or FakeProvider) │        │
│    │         └─► structured JSON output, schema-validated   │        │
│    │                                                        │        │
│    │  2. PolicyEngine.evaluate(action, order, policy) ─────►│        │
│    │     └─► Pipeline: Safety → Customer → Guardrails →     │        │
│    │         Policy → Operational score                     │        │
│    │                                                        │        │
│    │  3a. If approved + low risk:                          │        │
│    │      ActionExecutor.execute(action, idempotency_key)  │        │
│    │                                                        │        │
│    │  3b. If approved + high risk:                         │        │
│    │      ApprovalQueue.create → order → pending_approval  │        │
│    │      Turbo Stream broadcast → Dashboard               │        │
│    └────────────────────────────────────────────────────────┘        │
│                                                                       │
│  ┌──────────────────────────────────────────────────────────┐       │
│  │                    Simulators                             │       │
│  │  RestaurantSimulator | InventorySimulator                │       │
│  │  PaymentSimulator    | DeliverySimulator                 │       │
│  │  (each implements a defined Ruby interface)              │       │
│  └──────────────────────────────────────────────────────────┘       │
│                                                                       │
│  ┌──────────────────────────────────────────────────────────┐       │
│  │              Dashboard (/dashboard)                       │       │
│  │  Rails ERB + Hotwire Turbo Streams (Action Cable/Redis)  │       │
│  │                                                           │       │
│  │  Order Stream  │  Failure Feed  │  Recovery Queue        │       │
│  │  Approval Queue│  Metrics       │  Audit Timeline        │       │
│  └──────────────────────────────────────────────────────────┘       │
│                                                                       │
│  ┌──────────────────────────────────────────────────────────┐       │
│  │  FailureInjector (development + demo environments only)  │       │
│  └──────────────────────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────────┘
```

### Data Flow: Primary Demo Scenario

```
1. Order placed
   → Order.create (state: pending, lock_version: 0)
   → AuditRecord created
   → EventBus.publish(order.created)

2. Restaurant assigned
   → RestaurantRouter selects best available restaurant
   → OrderStateMachine.transition!(order, :pending → :assigned)
     (optimistic lock: lock_version 0 → 1)
   → EventBus.publish(order.state_changed)

3. Restaurant accepts
   → RestaurantSimulator callback → FailureDetector → restaurant.accepted event
   → OrderStateMachine.transition!(order, :assigned → :accepted)  [lock_version 1 → 2]
   → SlaMonitor starts acceptance phase timer

4. Order enters preparation
   → OrderStateMachine.transition!(order, :accepted → :preparing)  [lock_version 2 → 3]
   → SlaMonitor starts preparation phase timer

5. Simulated failure occurs
   → FailureInjector.inject(order_id:, failure_type: :KITCHEN_FAILURE)
   → EventBus.publish(failure.injected + kitchen.failure)  [injected: true]
   → FailureDetector emits typed failure event
   → OrderStateMachine.transition!(order, :preparing → :failed)  [lock_version 3 → 4]

6. SLA breach detection
   → SlaMonitor tick detects preparing phase breach
   → EventBus.publish(sla.breached)  [if not already transitioned]

7. AI diagnoses
   → RecoveryOrchestratorJob.perform(order_id, failure_event)
   → LlmAgent.diagnose(LlmContext.from(order, events, failure))
   → OpenAiProvider (or FakeProvider) returns structured JSON
   → Schema validation passes
   → Proposals: [{action: REROUTE_RESTAURANT, confidence: 0.85, evidence: [...]}]
   → AuditRecord: AI invocation with llm_model, llm_call_id, output

8. Policy validation
   → PolicyEngine.evaluate(REROUTE_RESTAURANT, order, policy_config)
   → Pipeline: Safety ✓ → Customer constraints ✓ → Guardrail: reroute_count=0 < 3 ✓
              → Policy: restaurant failure + preparing state = eligible ✓
   → PolicyDecision: approved: true, requires_human_approval: false
   → AuditRecord: policy evaluation with policy_version

9. Recovery executes
   → ActionExecutor.execute(:REROUTE_RESTAURANT, order, idempotency_key: "order_uuid:REROUTE:1")
   → recovery_actions INSERT (idempotency_key, status: pending)
   → RestaurantRouter finds next available restaurant
   → OrderStateMachine: :failed → :recovering → :assigned → :accepted → :preparing
     (each transition: lock_version increments, audit record written, Turbo Stream broadcast)
   → recovery_actions UPDATE (status: completed)
   → EventBus.publish(recovery.executed)

10. State verified
    → RecoveryOrchestrator confirms order.state == :preparing
    → order.reroute_attempt_count incremented to 1
    → SLA phase timer reset for new preparing phase

11. Audit trail
    → AuditRecord.for_order(order_id) returns 12+ records in sequence_number order
    → Record #5 has injected: true

12. Dashboard updates
    → Turbo Stream broadcasts pushed to all connected browsers
    → Order Stream: order now green (preparing, new restaurant, SLA reset)
    → Recovery Queue: shows "Recovered via REROUTE_RESTAURANT" with AI reasoning
    → Metrics: recovery_success_count + 1
```

---

## 6. Key Database Tables

| Table | Purpose |
|---|---|
| `orders` | Order aggregate with state, lock_version, SLA fields, items (jsonb), preferences (jsonb) |
| `audit_records` | Append-only event log; PostgreSQL trigger prevents UPDATE/DELETE |
| `recovery_actions` | Idempotency store for executed recovery actions; UNIQUE on idempotency_key |
| `approval_queue` | Pending and decided human approval requests |
| `customers` | Customer records (referenced by orders) |
| `restaurants` | Simulated restaurant records with capacity and availability |

---

## 7. Configuration Files

### `config/orderops.yml`
```yaml
llm:
  provider: openai        # openai | fake
  model: gpt-4o-mini
  timeout_seconds: 15

approvals:
  mode: manual            # manual | auto_approve (test/demo only)
  auto_approve_delay_seconds: 2

simulation:
  sla_tick_interval_seconds: 10
  restaurant_response_latency_ms: 500
  delivery_latency_seconds: 30

sla_thresholds:
  assignment_warning_seconds: 60
  assignment_breach_seconds: 120
  # ... (all phases)
```

### `config/orderops_policy.yml`
```yaml
version: "1.0.0"

reroute_limit: 3
reroute_approval_threshold: 2
full_refund_approval_threshold: 50.00
min_confidence_threshold: 0.5
approval_timeout_seconds: 120

refund_eligibility:
  KITCHEN_FAILURE:
    eligible_states: [failed, recovering]
    max_elapsed_minutes: 60
  # ...

fallback_recovery:
  KITCHEN_FAILURE: REROUTE_RESTAURANT
  DELIVERY_FAILURE: RETRY_DELIVERY
  PAYMENT_FAILURE: ESCALATE_TO_HUMAN
  # ...
```

---

## 8. Boundary: What V1 Does NOT Include

The following are explicitly out of scope. Do not start these until all 12 core capabilities are working and demonstrable.

| Feature | Category |
|---|---|
| Predictive SLA breach detection | Nice-to-have |
| ML-based dynamic re-routing | Nice-to-have |
| Multi-agent recovery chain | Nice-to-have |
| Customer impact scoring | Nice-to-have |
| What-if simulation | Nice-to-have |
| Chaos/failure console | Nice-to-have |
| Recovery analytics | Nice-to-have |
| Policy versioning and live reload | Nice-to-have |
| Adaptive routing | Nice-to-have |
| Kafka / Redis Streams event broker | Nice-to-have (ADR-03 defines the interface for this upgrade) |
| Amazon Bedrock LLM provider | Nice-to-have (ADR-09 defines the interface; implementation is one new class) |
| Customer allergy/dietary constraints | Stretch |
| Cross-contact/allergen tracking | Stretch |

---

## 9. All Architectural Decisions

All 10 original open questions are resolved. See [architecture.md](architecture.md) for full context.

| ADR | Decision | Status |
|---|---|---|
| ADR-01 | AI is advisory only; policy engine is the decision authority | Accepted |
| ADR-02 | Simulated integrations for V1; interface-backed for future swap | Accepted |
| ADR-03 | Event-driven via abstract EventBus; V1 uses ActiveJob/Redis adapter | Accepted |
| ADR-04 | OrderStateMachine is authoritative; optimistic concurrency via lock_version | Accepted |
| ADR-05 | Stack: Rails + PostgreSQL + Redis/Sidekiq + Hotwire | Accepted |
| ADR-06 | Policy externalised to YAML; pure function evaluation; version in audit trail | Accepted |
| ADR-07 | FailureInjector is first-class; gated to development/demo environments | Accepted |
| ADR-08 | Single LLM call per recovery event; deterministic fallback on AI failure | Accepted |
| ADR-09 | Abstract LlmProviders::Base; OpenAI default; FakeProvider for tests | Accepted |
| ADR-10 | Recovery actions use idempotency keys backed by PostgreSQL UNIQUE constraint | Accepted |
| ADR-11 | Human approval is default; auto_approve gated to test/demo environments | Accepted |
| ADR-12 | V1 order data model fully defined (15 columns including preferences and lock_version) | Accepted |
| ADR-13 | Policy evaluation pipeline order: Safety → Customer → Guardrails → Policy → Operational | Accepted |
| ADR-14 | AI output requires structured reasoning + evidence array; schema-validated | Accepted |
| ADR-15 | Audit trail is append-only PostgreSQL table enforced by DB trigger | Accepted |

---

## 10. Implementation Phases

### Phase 1 — Rails Scaffold and Core Plumbing
1. `rails new orderops --database=postgresql`; configure Redis, Sidekiq, Action Cable
2. Database migrations: `orders`, `audit_records`, `recovery_actions`, `approval_queue`, `customers`, `restaurants`
3. `OrderStateMachine` service with all states, transitions, and `StaleObjectError` handling
4. `EventBus` abstraction with `ActiveJobEventBusAdapter` and `SynchronousEventBusAdapter` (for tests)
5. `AuditTrail` event bus subscriber — writes to `audit_records`
6. PostgreSQL trigger on `audit_records` preventing UPDATE/DELETE

### Phase 2 — Simulators and Failure System
7. Simulator interfaces (`app/interfaces/`) and simulator implementations (`app/simulators/`)
8. `FailureDetector` — maps simulator callbacks to typed domain events
9. `FailureInjector` with environment guard

### Phase 3 — Monitoring and Routing
10. `SlaMonitor` with configurable thresholds; `SlaMonitorJob` on Sidekiq schedule
11. `RestaurantRouter` with routing criteria and rejection exclusion

### Phase 4 — Policy Engine
12. `config/orderops_policy.yml` with default rules for all 9 failure types
13. `PolicyConfiguration` loader with startup validation
14. `PolicyEngine` with 5-stage pipeline; RSpec unit tests to 100% branch coverage

### Phase 5 — AI Agent
15. `LlmProviders::Base` interface + `LlmProviders::FakeProvider`
16. `LlmProviders::OpenAiProvider` with HTTP client + timeout wrapper
17. `LlmAgent` — context builder, prompt template, JSON schema validator, fallback logic

### Phase 6 — Recovery Orchestration
18. `RecoveryAction` model with idempotency key and UNIQUE constraint
19. `ActionExecutor` with idempotency guard and simulator call
20. `RecoveryOrchestratorJob` wiring all components together

### Phase 7 — Human Approval
21. `ApprovalQueue` model and `ApprovalQueueController`
22. `ApprovalTimeoutJob`
23. Auto-approve mode with environment validation

### Phase 8 — Dashboard
24. Dashboard layout with all six panels as Turbo Frames
25. Turbo Stream broadcasts from `AuditTrail` and `RecoveryOrchestrator`
26. Approval queue form with approve/reject actions

### Phase 9 — Demo Polish
27. Seed script: `db/seeds/demo_scenario.rb` — creates orders, triggers failure injection, scripts the primary scenario
28. `FakeProvider` response fixtures for each failure type
29. Integration spec covering the full primary demo scenario end-to-end
30. Smoke test: start server, run demo script, verify audit trail completeness

---

## 11. Acceptance: Definition of Done

The specification is satisfied when:

1. All 12 requirements (REQ-01 through REQ-12) have implementations.
2. All acceptance criteria (AC-01.1 through AC-12.7) pass in RSpec.
3. The primary demo scenario (Section 5, Data Flow) runs end-to-end using `FakeProvider` without manual intervention, except the human approval step in `manual` mode.
4. The AI never directly calls a mutation function — verifiable by the absence of references to `OrderStateMachine`, `ActionExecutor`, `PolicyEngine`, or any ActiveRecord model in `app/services/llm_providers/`.
5. `PolicyEngine` unit tests have 100% branch coverage of all 6 guardrail rules and all 5 pipeline stages.
6. `AuditRecord.for_order(demo_order_id)` returns ≥ 12 records covering all steps of the demo scenario.
7. All 15 ADRs are reflected in the codebase structure; no ADR decision is contradicted by implementation.

---

## 12. Spec Files

| File | Contents |
|---|---|
| `orderops.md` (this file) | Overview, stack, architecture diagram, data flow, phases, DoD |
| `requirements.md` | Full requirements (REQ-01 – REQ-12) with acceptance criteria, data model, NFRs |
| `architecture.md` | All 15 ADRs; resolved questions summary; ambiguities table |
