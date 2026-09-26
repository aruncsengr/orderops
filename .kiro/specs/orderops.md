# OrderOps — Kiro Specification

**Project:** OrderOps  
**Challenge:** Kiro University  
**Version:** 0.1 (pre-implementation)  
**Status:** Specification — ready for architectural decisions, then implementation

---

## 1. What We Are Building

OrderOps is an AI-powered Order Reliability and Recovery Platform for food ordering systems. It solves a specific, high-value problem: orders can fail or become at risk *after* they have been placed, and existing systems have no structured way to detect, diagnose, and recover from those failures automatically.

OrderOps monitors every order through its lifecycle, detects failure conditions and SLA breaches, invokes an AI agent to diagnose the problem and propose recovery actions, validates those proposals through a deterministic policy engine, executes approved actions, and records everything in a complete audit trail.

---

## 2. The Core Problem

A food order can fail in many ways after placement:

- A restaurant rejects or stops responding
- An ingredient is unavailable (inventory failure)
- The kitchen is overloaded (delay) or fails (hard failure)
- A delivery courier fails or is delayed past acceptable SLA
- Payment processing fails or needs retry
- An external service (mapping, notifications, payment gateway) becomes unavailable

Each failure type has different recovery options with different risk levels, costs, and customer impacts. Without a structured system, operators make ad-hoc decisions, recovery is inconsistent, and nothing is auditable.

---

## 3. Core Architectural Principle

```
AI reasons and recommends.
Deterministic policies decide what is allowed.
Application services execute approved actions.
```

An LLM must never directly execute refunds, cancellations, or other high-risk operations. The AI's role is diagnosis and ranked proposal. The policy engine's role is approval or denial. The application layer's role is execution.

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

---

## 5. Architecture Overview

### Subsystems

```
┌─────────────────────────────────────────────────────────────────┐
│                        OrderOps Platform                         │
│                                                                   │
│  ┌─────────────┐   ┌──────────────┐   ┌────────────────────┐   │
│  │  Order      │   │  Event Bus   │   │   SLA Monitor      │   │
│  │  State      │◄──│  (typed,     │──►│   (tick-based,     │   │
│  │  Machine    │   │   internal)  │   │    configurable)   │   │
│  └──────┬──────┘   └──────┬───────┘   └────────────────────┘   │
│         │                  │                                      │
│  ┌──────▼──────┐   ┌──────▼───────┐   ┌────────────────────┐   │
│  │  Failure    │   │  Recovery    │   │   Restaurant       │   │
│  │  Detector   │──►│  Orchestrator│──►│   Router           │   │
│  └─────────────┘   └──────┬───────┘   └────────────────────┘   │
│                            │                                      │
│                    ┌───────▼──────┐                              │
│                    │  AI Agent    │  (read-only tools only)      │
│                    │  Interface   │                              │
│                    └───────┬──────┘                              │
│                            │ proposal                            │
│                    ┌───────▼──────┐                              │
│                    │  Policy &    │  (deterministic,             │
│                    │  Guardrail   │   stateless,                 │
│                    │  Engine      │   config-driven)             │
│                    └───────┬──────┘                              │
│                            │ approved action                     │
│          ┌─────────────────┼──────────────────┐                 │
│          │                 │                   │                 │
│  ┌───────▼──────┐  ┌───────▼──────┐  ┌────────▼────────┐      │
│  │  Human       │  │  Action      │  │  Audit Trail    │      │
│  │  Approval    │  │  Executor    │  │  (append-only)  │      │
│  │  Queue       │  └──────┬───────┘  └─────────────────┘      │
│  └──────────────┘         │                                      │
│                            ▼                                      │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    Simulators                            │   │
│  │  Restaurant | Inventory | Payment | Delivery            │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    Dashboard / UI                        │   │
│  │  Order Stream | Failure Feed | Recovery Queue |          │   │
│  │  Approval Queue | Metrics | Audit Timeline               │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### Data Flow: Primary Demo Scenario

```
1. Order placed
   → Order created (PENDING state)
   → EVENT: ORDER_CREATED

2. Restaurant assigned
   → Router selects restaurant
   → State: PENDING → ASSIGNED
   → EVENT: ORDER_STATE_CHANGED

3. Restaurant accepts
   → Simulator sends acceptance
   → State: ASSIGNED → ACCEPTED
   → EVENT: RESTAURANT_ACCEPTED, ORDER_STATE_CHANGED

4. Order enters preparation
   → State: ACCEPTED → PREPARING
   → EVENT: ORDER_STATE_CHANGED
   → SLA timer starts for PREPARING phase

5. Simulated failure occurs
   → Failure injection API injects KITCHEN_FAILURE
   → EVENT: FAILURE_INJECTED, KITCHEN_FAILURE detected
   → Failure detector emits typed failure event

6. SLA/Risk detection
   → SLA monitor detects breach (or imminent breach)
   → EVENT: SLA_BREACHED (or SLA_WARNING)

7. AI diagnoses the problem
   → Recovery orchestrator receives failure + SLA events
   → AI agent called with order context, event history, failure type
   → AI returns ranked proposals: [REROUTE_RESTAURANT (0.85), CANCEL_ORDER (0.40)]
   → EVENT: AI_DIAGNOSIS_COMPLETE (recorded in audit)

8. Policy engine validates
   → Policy engine evaluates REROUTE_RESTAURANT against policy + guardrails
   → APPROVED (re-route attempt 1 of 3, order not in terminal state, etc.)
   → EVENT: RECOVERY_APPROVED

9. Recovery action executes
   → Action executor calls Router to find new restaurant
   → New restaurant assigned
   → State machine: FAILED → PENDING → ASSIGNED → ACCEPTED → PREPARING
   → EVENT: RECOVERY_EXECUTED, ORDER_STATE_CHANGED (series)

10. Order state verified
    → Orchestrator confirms order is in PREPARING state with new restaurant
    → SLA clock resets for new PREPARING phase

11. Audit trail records everything
    → All 10+ events above are in the per-order audit log
    → Injected failure flag set on the failure event

12. Dashboard shows recovered order
    → Order stream shows order in PREPARING (green SLA)
    → Recovery queue shows completed recovery with AI diagnosis
    → Metrics: recovery success count + 1
```

---

## 6. Boundary: What V1 Does NOT Include

The following are explicitly out of scope for V1 and must not be started until all 12 core capabilities are working and demonstrable:

| Feature | Category |
|---|---|
| Predictive SLA breach detection | Nice-to-have |
| Dynamic re-routing (ML-based) | Nice-to-have |
| Recovery confidence scoring beyond AI output | Nice-to-have |
| Multi-agent recovery | Nice-to-have |
| Customer impact scoring | Nice-to-have |
| Customer recovery preferences | Nice-to-have |
| What-if simulation | Nice-to-have |
| Chaos/failure console | Nice-to-have |
| Recovery analytics | Nice-to-have |
| Explainability timeline | Nice-to-have |
| Policy versioning and simulation | Nice-to-have |
| Adaptive routing | Nice-to-have |
| Customer allergy/dietary safety constraints | Stretch |
| Cross-contact/allergen information | Stretch |
| Advanced customer recovery preferences | Stretch |

---

## 7. Decisions Required Before Implementation

The following open questions must be resolved before any code is written. See [architecture.md](architecture.md) for full context.

| # | Question | Blocking |
|---|---|---|
| OQ-01 | Concurrency model for order state (per-order lock vs. optimistic concurrency) | REQ-01, REQ-06 |
| OQ-02 | Technology stack (language, event bus, dashboard, persistence) | All |
| OQ-03 | Event bus ordering guarantees | REQ-02, REQ-06 |
| OQ-04 | AI agent: single call vs. chain (recommend single call for V1) | REQ-08 |
| OQ-05 | LLM provider and model | REQ-08 |
| OQ-06 | Audit trail persistence (in-memory vs. SQLite vs. Postgres) | REQ-11 |
| OQ-07 | Dashboard technology (TUI vs. lightweight web vs. SPA) | REQ-12 |
| OQ-08 | Recovery action idempotency strategy | REQ-06, REQ-07 |
| OQ-09 | Human approval: manual vs. auto-approve mode | REQ-10 |
| OQ-10 | V1 order data model fields | REQ-01, REQ-04, REQ-07 |

---

## 8. Implementation Phases (Post-Decision)

Once all open questions are resolved, implementation should proceed in this order to ensure the demo scenario is demonstrable as early as possible:

### Phase 1 — Core Plumbing (no AI yet)
1. Order state machine (REQ-01)
2. Event bus (REQ-02)
3. Simulator scaffolding (REQ-05 partial — just infrastructure)
4. Audit trail — append and query (REQ-11)

### Phase 2 — Detection and Monitoring
5. SLA monitor (REQ-03)
6. Failure detector (REQ-05)
7. Failure injection API (REQ-05)

### Phase 3 — Routing and Policy
8. Restaurant router (REQ-04)
9. Policy configuration format + loader (REQ-07)
10. Policy and guardrail engine (REQ-09)

### Phase 4 — AI and Recovery
11. AI agent interface + prompt design (REQ-08)
12. Recovery orchestrator (REQ-06)
13. Action executor (connects to simulators)

### Phase 5 — Human Layer and Dashboard
14. Human approval queue (REQ-10)
15. Dashboard (REQ-12)

### Phase 6 — Demo Polish
16. Primary demo scenario scripted and verified end-to-end
17. Failure injection wired into demo script
18. Integration tests for primary scenario

---

## 9. Acceptance: Definition of Done

The specification is satisfied when:

1. All 12 requirements (REQ-01 through REQ-12) have implementations.
2. All acceptance criteria (AC-01.1 through AC-12.7) can be demonstrated or tested.
3. The primary demo scenario (Section 5, Data Flow) runs end-to-end without manual intervention (except the human approval step).
4. The AI never directly executes a refund, cancellation, or state mutation — verifiable by code review of the AI agent interface.
5. The policy engine has 100% branch coverage for all guardrail rules (AC-09.5).
6. The audit trail contains a complete record for an order that went through the primary demo scenario.
7. All open questions (OQ-01 through OQ-10) are resolved and the decisions are recorded in architecture.md.

---

## 10. Spec Files

| File | Contents |
|---|---|
| `orderops.md` (this file) | Overview, architecture, data flow, phases, definition of done |
| `requirements.md` | Full requirements (REQ-01 – REQ-12) with acceptance criteria |
| `architecture.md` | Resolved architectural decisions (ADR-01 – ADR-07) and open questions (OQ-01 – OQ-10) |
