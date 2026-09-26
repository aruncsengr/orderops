# OrderOps — Requirements and Acceptance Criteria

## Overview

OrderOps is an AI-powered Order Reliability and Recovery Platform for food ordering systems. It monitors the order lifecycle, detects risk and failure conditions, determines safe recovery options, and executes or escalates recovery actions — always under the control of a deterministic policy engine.

### Guiding principle

> AI reasons and recommends. Deterministic policies decide what is allowed. Application services execute approved actions. An LLM must never directly execute refunds, cancellations, or other high-risk operations.

---

## Functional Requirements

### REQ-01 — Order Lifecycle and State Management

#### Description
The system must represent every order as a state machine with a well-defined set of states and allowed transitions. The state machine is the authoritative record of where an order is in its lifecycle.

#### States
| State | Meaning |
|---|---|
| `PENDING` | Order created, awaiting restaurant assignment |
| `ASSIGNED` | Restaurant assigned, awaiting acceptance |
| `ACCEPTED` | Restaurant accepted, awaiting preparation start |
| `PREPARING` | Kitchen is preparing the order |
| `READY_FOR_PICKUP` | Order ready, awaiting courier |
| `IN_DELIVERY` | Courier has picked up the order |
| `DELIVERED` | Order successfully delivered |
| `FAILED` | Terminal failure — order cannot be fulfilled |
| `CANCELLED` | Order cancelled by system, customer, or policy |
| `RECOVERED` | Order completed via a recovery path |
| `PENDING_APPROVAL` | Recovery action proposed; waiting for human approval |

#### Allowed Transitions
- `PENDING` → `ASSIGNED`, `CANCELLED`
- `ASSIGNED` → `ACCEPTED`, `FAILED`, `PENDING`  (re-route means back to PENDING)
- `ACCEPTED` → `PREPARING`, `FAILED`
- `PREPARING` → `READY_FOR_PICKUP`, `FAILED`
- `READY_FOR_PICKUP` → `IN_DELIVERY`, `FAILED`
- `IN_DELIVERY` → `DELIVERED`, `FAILED`
- `FAILED` → `PENDING_APPROVAL`, `RECOVERED`, `CANCELLED`
- `PENDING_APPROVAL` → `RECOVERING`, `CANCELLED`
- `RECOVERING` → `RECOVERED`, `FAILED`

#### Acceptance Criteria
- AC-01.1: Every order has a unique identifier and a current state persisted in the system.
- AC-01.2: An invalid state transition is rejected with a descriptive error; the order state does not change.
- AC-01.3: Every state transition produces a timestamped event in the audit trail (see REQ-11).
- AC-01.4: The system can retrieve full order state and metadata by order ID.
- AC-01.5: Concurrent state transition attempts on the same order are serialised; the second transition sees the result of the first.

---

### REQ-02 — Event-Driven Order Monitoring

#### Description
Order events (state transitions, external simulator events, SLA ticks, failure signals) must be published to an internal event bus. Other subsystems react to events rather than polling order state.

#### Event Types
- `ORDER_CREATED`, `ORDER_STATE_CHANGED`
- `RESTAURANT_ACCEPTED`, `RESTAURANT_REJECTED`, `RESTAURANT_UNAVAILABLE`
- `INVENTORY_FAILURE`
- `KITCHEN_DELAY`, `KITCHEN_FAILURE`
- `DELIVERY_DELAY`, `DELIVERY_FAILURE`
- `PAYMENT_FAILURE`
- `SLA_WARNING`, `SLA_BREACHED`
- `FAILURE_INJECTED` (from deterministic failure injection, see REQ-05)
- `RECOVERY_PROPOSED`, `RECOVERY_APPROVED`, `RECOVERY_REJECTED`, `RECOVERY_EXECUTED`
- `HUMAN_APPROVAL_REQUESTED`, `HUMAN_APPROVAL_RECEIVED`

#### Acceptance Criteria
- AC-02.1: All internal subsystems communicate through the event bus; no subsystem directly calls another's internal methods to change order state.
- AC-02.2: Events include: event type, order ID, timestamp, originating subsystem, and a payload containing relevant data.
- AC-02.3: Events are durable within a session — a newly registered handler can replay events since order creation.
- AC-02.4: The system supports at-least-once delivery of events to registered handlers.
- AC-02.5: Unhandled exceptions in an event handler do not crash other handlers or the event bus.

---

### REQ-03 — SLA Monitoring and Breach Detection

#### Description
Each order phase has a configurable time budget. The SLA monitor watches active orders and emits warnings when a phase is at risk and breach events when the budget is exceeded.

#### SLA Phases and Default Budgets
| Phase | Warning threshold | Breach threshold |
|---|---|---|
| Restaurant assignment | 60 s | 120 s |
| Restaurant acceptance | 90 s | 180 s |
| Order preparation | 600 s | 900 s |
| Pickup wait | 120 s | 240 s |
| Delivery | 1800 s | 2700 s |
| End-to-end (placed → delivered) | 2700 s | 3600 s |

#### Acceptance Criteria
- AC-03.1: The SLA monitor evaluates all active orders at least once per configurable tick interval (default 10 s in simulation).
- AC-03.2: An `SLA_WARNING` event is emitted when a phase reaches its warning threshold.
- AC-03.3: An `SLA_BREACHED` event is emitted when a phase exceeds its breach threshold.
- AC-03.4: SLA events include the affected order ID, the phase name, the time elapsed, and the threshold that was crossed.
- AC-03.5: SLA thresholds are configurable at system startup without code changes.
- AC-03.6: Once an order reaches a terminal state (`DELIVERED`, `CANCELLED`, `RECOVERED`, `FAILED`), SLA monitoring for that order stops.
- AC-03.7: The dashboard (see REQ-12) shows a live count of orders in WARNING and BREACHED state.

---

### REQ-04 — Restaurant Routing and Re-Routing

#### Description
When an order needs a restaurant, or when the current restaurant fails, the routing subsystem selects the best available restaurant from the simulator's restaurant pool.

#### Routing Criteria (in priority order)
1. Restaurant is available (not at capacity, not marked unavailable)
2. Restaurant supports the required cuisine type
3. Restaurant is within configurable maximum distance
4. Restaurant has the lowest current queue depth

#### Re-Routing Triggers
- Restaurant rejects the order
- Restaurant becomes unavailable after acceptance
- SLA breach in the `ACCEPTED` or `PREPARING` state with a recoverable restaurant failure
- Explicit recovery action approved by the policy engine

#### Acceptance Criteria
- AC-04.1: The router returns the top-ranked available restaurant or a `NO_RESTAURANT_AVAILABLE` result with a reason.
- AC-04.2: A restaurant that previously rejected the same order is excluded from re-routing candidates.
- AC-04.3: Re-routing does not mutate order state directly; it produces a routing decision that is applied via the state machine.
- AC-04.4: If no restaurant is available after re-routing, the order moves to `FAILED` and an escalation event is emitted.
- AC-04.5: The simulator exposes a method to mark a specific restaurant as unavailable for testing re-routing.
- AC-04.6: Routing decisions are recorded in the audit trail with the reason for restaurant selection or rejection.

---

### REQ-05 — Failure Detection and Injection

#### Description
The system must detect real-world failure conditions reported by simulators, and must also support deterministic failure injection for demonstration and testing purposes.

#### Detectable Failure Types
| Code | Description |
|---|---|
| `RESTAURANT_REJECTION` | Restaurant explicitly rejects the order |
| `RESTAURANT_UNAVAILABLE` | Restaurant goes offline after acceptance |
| `INVENTORY_FAILURE` | Item(s) unavailable; kitchen cannot fulfill |
| `KITCHEN_DELAY` | Preparation exceeding SLA |
| `KITCHEN_FAILURE` | Hard kitchen failure, order cannot be prepared |
| `DELIVERY_DELAY` | Delivery exceeding SLA |
| `DELIVERY_FAILURE` | Courier lost, accident, or hard failure |
| `PAYMENT_FAILURE` | Payment declined or processing error |
| `EXTERNAL_SERVICE_FAILURE` | Simulator integration failure |

#### Failure Injection API
The system must expose a failure injection interface allowing:
- Inject a specific failure type into a specific order at a specific order state
- Schedule a failure to occur after a configurable delay
- Clear all pending injections

#### Acceptance Criteria
- AC-05.1: Each detected failure emits a typed failure event with: failure code, order ID, affected subsystem, and a human-readable description.
- AC-05.2: The failure injection API can inject any failure type against any active order.
- AC-05.3: Injected failures produce the same events and trigger the same detection pipeline as naturally occurring failures.
- AC-05.4: The `FAILURE_INJECTED` event is recorded separately in the audit trail to distinguish injected from natural failures.
- AC-05.5: The system does not allow failure injection against orders in terminal states.
- AC-05.6: All failure types listed above are detectable by the failure detection subsystem.

---

### REQ-06 — Recovery Orchestration

#### Description
When a failure or SLA breach is detected, the recovery orchestrator coordinates diagnosis (via AI, REQ-08), policy validation (REQ-09), execution, and escalation.

#### Recovery Actions
| Action | Description |
|---|---|
| `REROUTE_RESTAURANT` | Assign a different restaurant |
| `PARTIAL_REFUND` | Issue a partial refund and continue |
| `FULL_REFUND` | Cancel and fully refund |
| `ISSUE_VOUCHER` | Issue a compensation voucher |
| `ESCALATE_TO_HUMAN` | Request human operator decision |
| `CANCEL_ORDER` | Cancel without refund (policy-defined conditions) |
| `RETRY_DELIVERY` | Attempt delivery re-assignment |
| `CONTACT_CUSTOMER` | Flag for customer notification |

#### Recovery Flow
1. Failure or SLA breach event received
2. AI agent diagnoses (REQ-08) and proposes one or more ranked recovery actions
3. Policy engine validates each proposed action (REQ-09)
4. If approved and not high-risk: execute immediately
5. If approved and high-risk: request human approval (REQ-10)
6. If rejected by policy: move to next proposed action or escalate
7. Execute approved action via application service
8. Verify post-recovery order state
9. Record everything in audit trail (REQ-11)

#### Acceptance Criteria
- AC-06.1: The orchestrator handles every failure type in REQ-05 and produces at least one candidate recovery action.
- AC-06.2: Recovery actions are never executed without passing through the policy engine.
- AC-06.3: If all candidate recovery actions are rejected by policy, the order is escalated to a human operator.
- AC-06.4: Recovery execution updates the order state machine via defined transitions (not bypassing it).
- AC-06.5: The orchestrator emits `RECOVERY_PROPOSED`, `RECOVERY_APPROVED`/`RECOVERY_REJECTED`, and `RECOVERY_EXECUTED` events.
- AC-06.6: A recovery that fails mid-execution leaves the order in `FAILED` state and emits an escalation event; it does not silently discard the error.
- AC-06.7: The system can handle concurrent recovery attempts on different orders without interference.

---

### REQ-07 — Refund and Compensation Policy Management

#### Description
Refund and compensation rules must be defined as explicit, versioned policy documents — not embedded in AI reasoning or arbitrary code.

#### Policy Dimensions
- Refund eligibility: which failure types qualify, under what order states, within what time window
- Compensation amounts: percentage or fixed, relative to order total
- Voucher issuance: when vouchers may substitute or supplement refunds
- Escalation thresholds: when an action requires human approval (see REQ-10)
- Cooldown/anti-abuse: how frequently a customer may receive compensation

#### Acceptance Criteria
- AC-07.1: All refund and compensation rules are defined in a configuration file or structured data store — not in code logic.
- AC-07.2: The policy engine can evaluate a proposed refund/compensation action against the active policy and return APPROVED or DENIED with a reason.
- AC-07.3: Policy evaluation is deterministic — the same inputs always produce the same output.
- AC-07.4: Policies have a version identifier; the version is recorded in the audit trail when a policy evaluation occurs.
- AC-07.5: The system ships with a default policy covering all failure types in REQ-05.
- AC-07.6: A `FULL_REFUND` for an order over a configurable threshold (default: $50) always requires human approval regardless of other policy conditions.

---

### REQ-08 — AI-Assisted Failure Diagnosis and Recovery Planning

#### Description
An LLM agent analyses failure context and proposes ranked recovery actions with reasoning. The AI role is strictly advisory — it cannot directly mutate order state or execute financial operations.

#### AI Agent Inputs
- Current order state and metadata
- Full event history for the order
- Detected failure type and description
- Available recovery actions (filtered by policy to actions the AI is allowed to propose)
- Restaurant availability summary
- SLA status

#### AI Agent Outputs
- Ranked list of proposed recovery actions, each with:
  - Action type (from the defined list in REQ-06)
  - Confidence score (0.0 – 1.0)
  - Plain-language reasoning
  - Estimated customer impact (LOW / MEDIUM / HIGH)
- Diagnosis summary (plain text, shown in dashboard and audit trail)

#### Constraints
- The AI must not invent action types outside the defined list in REQ-06.
- The AI must not include customer PII in reasoning text stored in the audit trail.
- AI calls must be wrapped so that a failure in the LLM (timeout, error, invalid output) falls back to a default rule-based recovery path.

#### Acceptance Criteria
- AC-08.1: For every detected failure, the AI agent is invoked and produces at least one proposed recovery action within a configurable timeout (default: 15 s).
- AC-08.2: AI output is structured (typed, not free-form) and validated against a schema before being passed to the policy engine.
- AC-08.3: If the AI fails or times out, the system uses a deterministic fallback recovery strategy and logs the fallback reason.
- AC-08.4: The AI cannot call any tool or function that mutates order state, issues refunds, or executes financial operations.
- AC-08.5: Each AI diagnosis and proposal is stored in the audit trail, including the model name, input summary, and output.
- AC-08.6: The AI proposal includes a confidence score and reasoning string for each suggested action.

---

### REQ-09 — Deterministic Policy and Guardrail Engine

#### Description
The policy engine is the sole decision authority for whether a recovery action may execute. It is stateless, deterministic, and operates independently of the AI.

#### Guardrail Rules (always enforced, cannot be overridden by AI)
1. A refund may not exceed the original order total.
2. A `FULL_REFUND` cannot be executed if the order has already been partially delivered.
3. `REROUTE_RESTAURANT` cannot be attempted more than N times (configurable, default: 3) for the same order.
4. No action may be executed on an order in a terminal state.
5. A `CANCEL_ORDER` action requires either a human approval or a policy-defined automatic condition (e.g., payment failure with no items prepared).
6. An action that would cause a duplicate refund is denied.

#### Acceptance Criteria
- AC-09.1: The policy engine evaluates all six guardrail rules before approving any recovery action.
- AC-09.2: If any guardrail rule fails, the action is DENIED and the denial reason cites which rule was violated.
- AC-09.3: The policy engine also applies the configurable refund/compensation policies from REQ-07.
- AC-09.4: Policy evaluation takes no external I/O — it is a pure function over order state and policy configuration.
- AC-09.5: The policy engine is unit-testable independently of the rest of the system.
- AC-09.6: All policy evaluations (approved and denied) are logged in the audit trail.

---

### REQ-10 — Human Approval for High-Risk Actions

#### Description
Certain recovery actions require a human operator to review and approve before execution. The system must queue these requests, surface them in the UI, and block execution until a decision is received.

#### High-Risk Action Triggers (any of the following)
- Action type is `FULL_REFUND` and order total exceeds configurable threshold (default: $50)
- Action type is `CANCEL_ORDER` and order is in `PREPARING` or later state
- Re-routing attempt count ≥ configurable limit (default: 2)
- AI confidence score < configurable threshold (default: 0.5) for the top-ranked action
- Policy configuration explicitly marks an action as requiring approval

#### Approval Workflow
1. System emits `HUMAN_APPROVAL_REQUESTED` event and places order in `PENDING_APPROVAL` state
2. Dashboard shows the pending request with full context (order, failure, AI diagnosis, proposed action)
3. Operator approves or rejects with an optional note
4. System emits `HUMAN_APPROVAL_RECEIVED` event and proceeds accordingly
5. SLA monitoring continues during approval wait; a separate approval SLA timer fires if unanswered beyond a configurable timeout (default: 120 s)

#### Acceptance Criteria
- AC-10.1: Any action classified as high-risk (per the triggers above) is blocked until human approval is received.
- AC-10.2: The dashboard displays all pending approvals with order ID, failure type, AI diagnosis, proposed action, confidence score, and elapsed wait time.
- AC-10.3: An operator can approve or reject a pending request from the dashboard.
- AC-10.4: If the approval timeout expires with no decision, the system escalates (emits an escalation event) and optionally executes a safe fallback action per policy.
- AC-10.5: Approved and rejected decisions are recorded in the audit trail with the operator identifier and timestamp.
- AC-10.6: The system does not process multiple simultaneous approvals for the same order.

---

### REQ-11 — Complete Audit Trail

#### Description
Every meaningful event in the system is recorded immutably in a per-order audit log. The audit trail must be comprehensive enough to reconstruct the full history of any order after the fact.

#### Audit Record Fields
- Record ID (unique)
- Order ID
- Timestamp (UTC, millisecond precision)
- Event type
- Originating subsystem
- Actor (system component, AI agent, human operator, or simulator)
- Before state (where applicable)
- After state (where applicable)
- Payload (event-specific structured data)
- Policy version (where a policy evaluation occurred)
- AI model name and call ID (where an AI call occurred)
- Injected failure flag (true if the event was artificially injected)

#### Acceptance Criteria
- AC-11.1: Every state transition produces an audit record.
- AC-11.2: Every policy evaluation (approved or denied) produces an audit record.
- AC-11.3: Every AI invocation produces an audit record including the input context summary and output.
- AC-11.4: Every human approval request and decision produces an audit record with the operator identity.
- AC-11.5: Audit records are append-only within a session; no record may be modified or deleted.
- AC-11.6: The full audit trail for any order is retrievable by order ID.
- AC-11.7: The demo dashboard can render a chronological timeline of an order's audit trail.

---

### REQ-12 — Operational Observability

#### Description
The system must provide a real-time operational dashboard showing system health, active order status, SLA state, and recovery activity. For V1 this is a terminal-based or lightweight web UI.

#### Dashboard Panels
1. **Order Stream** — live list of active orders with current state, phase, and SLA colour (green / amber / red)
2. **Failure Feed** — real-time stream of failure events with type, order, and elapsed time
3. **Recovery Queue** — pending and in-progress recoveries with AI diagnosis summary
4. **Approval Queue** — pending human approvals (see REQ-10)
5. **System Metrics** — counts of orders by state, recovery success rate, average recovery time
6. **Audit Timeline** — per-order chronological event timeline (on demand)

#### Acceptance Criteria
- AC-12.1: The dashboard refreshes automatically; operators do not need to manually reload.
- AC-12.2: Each active order is visible with its current state and SLA colour code.
- AC-12.3: The failure feed shows failures in real-time as they occur.
- AC-12.4: The recovery queue shows the AI's diagnosis summary and proposed action for each in-progress recovery.
- AC-12.5: The approval queue allows an operator to action a pending approval from within the dashboard.
- AC-12.6: System metrics include: total orders, orders in WARNING state, orders in BREACHED state, recovery success count, recovery failure count.
- AC-12.7: An audit timeline for any order can be opened from the dashboard by order ID.

---

## Non-Functional Requirements

### NFR-01 — Simulation Fidelity
- All external integrations (restaurant, inventory, payment, delivery) are implemented as in-process simulators.
- Simulators must support configurable latency, failure rates, and capacity limits.
- Simulators must support deterministic failure injection (see REQ-05).

### NFR-02 — Testability
- Each subsystem (state machine, event bus, SLA monitor, router, policy engine, AI agent interface, recovery orchestrator, audit trail) must be independently unit-testable.
- Integration tests must cover the primary demo scenario end-to-end.
- The policy engine must have 100% branch coverage in unit tests for all guardrail rules.

### NFR-03 — Configurability
- All SLA thresholds, policy limits, high-risk action thresholds, and simulation parameters must be configurable via a single configuration file at startup.
- No business rule may be hard-coded as a magic number.

### NFR-04 — Extensibility
- Adding a new failure type should require changes in at most three files: failure type definition, default policy, and failure detector.
- Adding a new recovery action should require changes in at most three files: action type definition, default policy, and action executor.

### NFR-05 — Reliability of the AI Boundary
- The boundary between the AI agent and the rest of the system must be explicit and enforced at the type/interface level.
- The AI can only call a defined, restricted set of read-only tools; it has no access to state mutation or financial operation functions.
