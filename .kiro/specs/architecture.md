# OrderOps — Architectural Decisions and Open Questions

## Resolved Architectural Decisions

---

### ADR-01 — AI Is Advisory Only; Policy Engine Is the Decision Authority

**Status:** Accepted

**Context:**
The system deals with refunds, cancellations, and financial compensation. Allowing an LLM to directly execute these operations introduces unacceptable risks: hallucinated actions, inconsistent policy application, and auditability gaps.

**Decision:**
The LLM agent may only read order context and propose recovery actions from a fixed, pre-defined list. The policy engine independently validates every proposed action. Application services execute approved actions. No execution path exists that bypasses the policy engine.

**Consequences:**
- The system is more complex (three layers instead of one), but far safer.
- The AI can be swapped or upgraded without changing execution logic.
- Every decision is auditable because the policy engine produces a structured decision record.
- The AI cannot invent novel actions; it can only rank and reason about the defined action types.

---

### ADR-02 — Simulated Integrations for V1

**Status:** Accepted

**Context:**
Real restaurant, payment, inventory, and delivery APIs introduce external dependencies, rate limits, costs, and unreliable test conditions. For the Kiro University challenge demo, we need full control over failure scenarios.

**Decision:**
All external integrations are in-process simulators. Simulators conform to an interface contract identical to what a real integration would satisfy. The rest of the system depends only on the interface, not the simulator implementation.

**Consequences:**
- We can demonstrate any failure scenario deterministically.
- Replacing simulators with real integrations in a future version is a matter of swapping the implementation, not redesigning the system.
- Simulator latency and failure rates are configurable to make demos realistic.

---

### ADR-03 — Event-Driven Internal Architecture

**Status:** Accepted

**Context:**
The order lifecycle involves multiple subsystems (SLA monitor, failure detector, recovery orchestrator, audit trail, dashboard). Direct method calls between them would create tight coupling and make it impossible to add new observers without modifying existing components.

**Decision:**
All subsystems communicate through a typed internal event bus. State-mutating operations still go through the state machine; the event bus is used for notification and reaction, not for direct state mutation.

**Consequences:**
- Any new subsystem (e.g., a future analytics module) can subscribe to events without touching existing code.
- The audit trail can passively record all events without being called explicitly.
- Care must be taken to avoid event storms: a subsystem reacting to an event must not emit another event that triggers itself in a loop.
- Event ordering guarantees must be documented (see Open Questions, OQ-03).

---

### ADR-04 — State Machine is the Authoritative Order State

**Status:** Accepted

**Context:**
Multiple subsystems react to and potentially attempt to change order state. Without a single authority, race conditions and inconsistent state are likely.

**Decision:**
All state transitions go through the state machine module. The state machine enforces allowed transitions, rejects invalid ones, and emits a state-changed event. No subsystem sets order state directly.

**Consequences:**
- State integrity is guaranteed by a single enforcement point.
- Concurrent transition attempts must be serialised at the state machine level (see OQ-01).
- The state machine must be tested exhaustively for all valid and invalid transitions.

---

### ADR-05 — Policy Configuration Externalised from Code

**Status:** Accepted

**Context:**
Refund thresholds, compensation limits, re-routing limits, and approval triggers are business rules that will change without code deployments. Embedding them in code makes changes expensive and error-prone.

**Decision:**
All policy parameters are defined in a structured configuration file (YAML or JSON) loaded at startup. The policy engine reads from this configuration; it contains no hard-coded business values. Policy files have a version field.

**Consequences:**
- Policies can be reviewed and changed by non-engineers.
- Policy version is recorded in the audit trail, enabling post-hoc analysis.
- Policy changes require a system restart in V1 (live reload is a future enhancement).

---

### ADR-06 — Deterministic Fallback for AI Failure

**Status:** Accepted

**Context:**
LLM calls can fail, time out, or return structurally invalid output. The system must not halt or expose an unhandled error to the operator because the AI is unavailable.

**Decision:**
The AI agent interface has a fallback mode. If the AI call fails or exceeds the configurable timeout, the system applies a deterministic rule-based recovery strategy (e.g., attempt re-route, then escalate to human). The fallback reason is recorded in the audit trail.

**Consequences:**
- System availability does not depend on LLM availability.
- Fallback decisions are clearly labelled in the audit trail.
- The fallback strategy must be explicitly defined for each failure type (not just "do nothing").

---

### ADR-07 — Failure Injection Is a First-Class Feature

**Status:** Accepted

**Context:**
The demo must showcase real failure scenarios. Relying on natural simulator failures produces non-deterministic demo outcomes.

**Decision:**
The failure injection subsystem is a first-class module with a formal API, not a test hack. It injects failures via the same event bus used by real failures. Injected failures are marked with a flag in the audit trail.

**Consequences:**
- The demo scenario is fully scripted and repeatable.
- The distinction between injected and natural failures is preserved in the audit trail.
- The failure injection API is not exposed in production (guarded by a feature flag or removed from the production configuration).

---

## Open Questions

These questions must be resolved before implementation begins in each affected area. Each question is tagged with the requirements it affects.

---

### OQ-01 — Concurrency Model for Order State

**Affects:** REQ-01, REQ-06

**Question:**
How do we serialise concurrent state transition attempts in V1? Options:
1. Per-order mutex/lock in memory (simplest, works for single-process V1)
2. Optimistic concurrency with a version field on the order (more robust, required for multi-process)
3. Actor model (e.g., one actor per order)

**Implication:**
For the Kiro challenge demo, the system is likely single-process. A per-order lock is probably sufficient. However, if the architecture uses async tasks (e.g., async Rust, Python asyncio, Node.js), "lock" means an async mutex. If multi-process distribution is in scope, optimistic concurrency is needed.

**Decision needed:** Choose the concurrency model before implementing the state machine.

---

### OQ-02 — Technology Stack

**Affects:** All

**Question:**
What language and framework will OrderOps be implemented in? Relevant considerations:
- LLM integration: Python (most mature ecosystem), TypeScript (good async model), Rust (strong types, performance — but less LLM tooling)
- Event bus: in-process vs. external (Redis Streams, Kafka, etc.)
- Dashboard: TUI (Rich/Textual for Python, Ratatui for Rust), lightweight web (FastAPI + HTMX, Express), or full SPA
- State persistence: in-memory (V1), SQLite, or Postgres

**Implication:**
The architecture is compatible with any of these. The choice affects how the AI agent interface is implemented, the event bus implementation, and the dashboard technology. For the Kiro challenge, something that runs with `docker compose up` or even just `python main.py` is preferable.

**Decision needed:** Choose the stack before creating the project scaffold.

---

### OQ-03 — Event Bus Ordering Guarantees

**Affects:** REQ-02, REQ-06, REQ-11

**Question:**
Does the internal event bus guarantee per-order ordering of events? If two events are published for the same order simultaneously (e.g., `SLA_BREACHED` and `FAILURE_INJECTED`), in what order do handlers receive them?

**Implication:**
If events for the same order can arrive out of order at the recovery orchestrator, we may attempt to start recovery twice. We need to decide:
- Option A: Event bus guarantees per-order FIFO ordering
- Option B: Consumers deduplicate by checking current order state before acting
- Option C: Both (belt and suspenders)

**Decision needed:** Define the event ordering contract before implementing the orchestrator.

---

### OQ-04 — AI Agent: Single Agent or Multi-Agent?

**Affects:** REQ-08

**Question:**
Should the AI diagnosis and recovery planning be performed by a single LLM call with a structured prompt, or by a chain of agent calls (e.g., one call to diagnose, one to propose actions, one to estimate impact)?

**Implication:**
- Single call: simpler, fewer failure modes, lower latency
- Multi-call chain: can produce richer reasoning, each step is auditable separately
- Multi-agent (parallel): specialised agents per failure type — powerful but over-engineered for V1

**Recommendation:** Single structured call for V1. The interface should be designed so the internal implementation can be swapped to multi-agent later without changing the caller.

**Decision needed:** Confirm single-call approach for V1.

---

### OQ-05 — LLM Provider and Model

**Affects:** REQ-08

**Question:**
Which LLM provider and model will be used for the AI agent?

Options:
- Amazon Bedrock (Claude Sonnet / Haiku) — appropriate for AWS-focused challenge
- OpenAI (GPT-4o / GPT-4o-mini) — widely available
- Local model (Ollama) — runs offline, reproducible demo, but lower quality
- Configurable at startup (recommended)

**Implication:**
The AI agent interface must abstract the LLM provider. The concrete provider is injected at startup. This also affects what credentials the demo environment needs.

**Decision needed:** Choose the default provider for the demo. The interface should support swapping.

---

### OQ-06 — Audit Trail Persistence

**Affects:** REQ-11

**Question:**
Where is the audit trail stored in V1?
- Option A: In-memory list (simplest, lost on restart, fine for demo)
- Option B: SQLite file (persists across restarts, still zero-dependency)
- Option C: Postgres (production-grade, requires Docker)

**Implication:**
For a demo, in-memory or SQLite is sufficient. However, if the dashboard needs to replay events from a previous run, persistence is required.

**Decision needed:** Define the V1 persistence strategy. SQLite is recommended as the baseline — it adds minimal complexity but makes demos restartable.

---

### OQ-07 — Dashboard Technology

**Affects:** REQ-12

**Question:**
What is the dashboard implementation approach?
- Option A: Terminal UI (TUI) — no browser required, works everywhere the CLI runs
- Option B: Lightweight web (FastAPI + HTMX or similar) — richer UI, browser required
- Option C: Full SPA (React/Vue) — maximum interactivity, significantly more build complexity

**Implication:**
For the Kiro challenge demo, the dashboard needs to be impressive but achievable. A lightweight web dashboard served by the same process (Option B) provides a good balance. The approval queue (REQ-10) particularly benefits from a web UI since it involves operator interaction.

**Decision needed:** Confirm dashboard approach before building REQ-12.

---

### OQ-08 — Recovery Action Idempotency

**Affects:** REQ-06, REQ-07, REQ-09

**Question:**
If a recovery action (e.g., partial refund) is executed and the system crashes before recording success, and then restarts, could the action be executed twice?

**Implication:**
This is the classic "exactly-once execution" problem. For V1 with simulators and in-memory state, the risk is theoretical. However, the architecture should:
- Record "execution started" before calling the simulator
- Record "execution completed" after
- On recovery (from a crash), check for "started but not completed" records and apply a compensating action or flag for human review

**Decision needed:** Define the idempotency strategy. At minimum, document the known gap in V1 and add a guardrail rule to detect duplicate refund attempts (already in REQ-09).

---

### OQ-09 — Human Approval in the Demo: Who Is the Operator?

**Affects:** REQ-10, REQ-12

**Question:**
In the demo scenario, who plays the human operator who approves high-risk recovery actions? Options:
- The demo presenter manually approves from the dashboard
- An automatic "simulated operator" approves after a configurable delay
- Both modes are supported (manual by default, auto-approve mode for automated demos)

**Implication:**
For a live challenge demo, manual approval makes the AI-human collaboration visible and compelling. An auto-approve mode is useful for automated end-to-end tests.

**Decision needed:** Support both modes; manual is default, auto-approve is configurable.

---

### OQ-10 — Scope of V1 Order Data Model

**Affects:** REQ-01, REQ-04, REQ-07

**Question:**
How much detail should the V1 order data model include?

Minimum viable fields:
- Order ID, customer ID, restaurant ID
- Item list (name, quantity, price)
- Order total
- Cuisine type
- Timestamps (created, state transitions)
- Current state, SLA phase

Potential additions:
- Delivery address (needed for distance-based routing)
- Payment method and payment intent ID (needed for refund simulation)
- Customer contact preference (nice-to-have, stretch)

**Decision needed:** Define the minimum data model before starting implementation. Delivery address and payment method are recommended inclusions even in V1, since routing and refund simulation depend on them.

---

## Ambiguities in the Problem Statement

These are ambiguities in the original brief that were resolved by the decisions above, noted here for transparency.

| # | Ambiguity | Resolution |
|---|---|---|
| A1 | "AI-assisted" — does this mean the AI executes or advises? | ADR-01: AI is strictly advisory. |
| A2 | "Simulated restaurants" — single simulator or per-restaurant? | Each simulated restaurant is a separate object with its own state, capacity, and failure probability. |
| A3 | "Human approval for high-risk actions" — who is the human in the demo? | OQ-09: presenter by default, auto-approve mode available. |
| A4 | "Recovery orchestration" — synchronous or async? | Async via event bus; the orchestrator reacts to events and emits its own events. |
| A5 | "Complete audit trail" — in-memory for demo or persistent? | OQ-06: SQLite recommended. |
| A6 | "Operational observability" — what does V1 need to show? | REQ-12 defines six panels. TUI or lightweight web. |
