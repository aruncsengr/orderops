# Requirements Document — Safe Order Recovery

## Introduction

Safe Order Recovery is the core reliability feature of the OrderOps platform. It provides a structured, auditable pipeline for detecting order failures, diagnosing the cause via an AI agent, evaluating recovery options through a deterministic policy engine, obtaining human approval when required, and executing the approved recovery action — all within a Ruby on Rails 8.1 application backed by PostgreSQL and surfaced through a Hotwire/Turbo real-time dashboard.

The feature is scoped to produce a compelling 5-minute live demo that showcases two end-to-end scenarios:

- **Scenario 1 — Automatic Restaurant Reroute**: A `KITCHEN_FAILURE` is injected on an order in `PREPARING` state. The system diagnoses, proposes `REROUTE_RESTAURANT`, the policy engine approves automatically, and the order reaches `RECOVERED` without operator intervention.
- **Scenario 2 — Human Approval for Refund**: A `DELIVERY_FAILURE` triggers a `FULL_REFUND` proposal that exceeds the automatic approval threshold ($50). The order enters `PENDING_APPROVAL`, an operator approves from the dashboard, and the refund simulator executes.

The guiding principle throughout:

> **AI reasons and recommends. The PolicyEngine decides. A human approves when required. The ActionExecutor acts only on approved decisions.**

The AI agent (`RecoveryAgent`) is strictly read-only. It cannot mutate `Order` records, transition order state, execute refunds, call `ActionExecutor`, bypass `PolicyEngine`, or invoke simulator mutations directly.

### Scope

In scope for this feature:
- Order state machine (lifecycle states and valid transitions)
- Failure event creation and failure injection API
- AI-assisted failure diagnosis (single structured LLM call; `FakeProvider` for initial implementation)
- Deterministic policy and guardrail engine (YAML-configured rules)
- Human approval workflow (dashboard queue, approve/reject)
- Recovery action execution via in-process simulators
- Append-only audit trail with Turbo Stream timeline
- Real-time dashboard panels (order stream, failure feed, recovery queue, approval queue)
- Background job orchestration via Solid Queue
- WebSocket push via Solid Cable

Out of scope: see [Non-Goals](#non-goals).

---

## Glossary

- **Order**: A food order record with a current lifecycle state, persisted in PostgreSQL. The authoritative state is managed by the `OrderStateMachine`.
- **OrderStateMachine**: The Rails model layer (using AASM or `state_machines-activerecord`) that is the sole authority for valid order state transitions.
- **FailureEvent**: A domain record representing a detected or injected failure condition on a specific order.
- **FailureInjector**: A first-class module that creates `FailureEvent` records via the same pipeline as naturally occurring failures, used for demo scripting and testing.
- **RecoveryAgent**: The AI agent component. Accepts read-only order context and returns a ranked list of proposed `RecoveryAction` records. Cannot mutate any record.
- **FakeProvider**: A deterministic, in-process LLM stub that returns hardcoded structured responses. Used in initial implementation and tests.
- **PolicyEngine**: A stateless, deterministic service that evaluates a proposed `RecoveryAction` against the active `PolicyConfig` and the six guardrail rules. Returns `APPROVED` or `DENIED` with a reason.
- **PolicyConfig**: A versioned YAML configuration file loaded at startup. Contains all business thresholds (refund limits, reroute caps, approval triggers). No magic numbers in code.
- **GuardrailRules**: Six hard-coded, non-overridable safety constraints evaluated by the `PolicyEngine` before any configurable policy check.
- **RecoveryAction**: A record representing a single proposed or executed recovery action on an order. Tracks `status` through `proposed → approved/rejected → executed/failed`.
- **ApprovalRequest**: A record linking a `RecoveryAction` to a human operator decision. Created when the `PolicyEngine` determines human approval is required.
- **ActionExecutor**: The service that executes an approved `RecoveryAction` by calling the appropriate in-process simulator. Called only after `PolicyEngine` approval (and optional human approval).
- **Simulator**: An in-process Ruby object that mimics a real external service (restaurant, inventory, payment, delivery). Supports configurable latency, failure rates, and deterministic failure injection.
- **AuditEvent**: An append-only PostgreSQL record capturing every meaningful event in the system (state transitions, policy decisions, AI calls, human decisions, failures).
- **RecoveryOrchestrator**: A Solid Queue background job that coordinates the full recovery pipeline: `FailureEvent` → `RecoveryAgent` → `PolicyEngine` → approval gate → `ActionExecutor` → state verification → `AuditEvent`.
- **ApprovalQueue**: The dashboard panel showing `ApprovalRequest` records awaiting operator decision.
- **Turbo Stream**: Hotwire mechanism delivering real-time partial-page updates to the dashboard without a full page reload.
- **EARS**: Easy Approach to Requirements Syntax — the requirement pattern language used throughout this document.

---

## Requirements

### Requirement 1: Order State Machine

**User Story:** As an OrderOps operator, I want every order to progress through a well-defined set of lifecycle states with enforced transition rules, so that the system always has a trustworthy, authoritative record of where an order is.

#### Acceptance Criteria

1. THE `OrderStateMachine` SHALL define the following states: `PENDING`, `ASSIGNED`, `ACCEPTED`, `PREPARING`, `READY_FOR_PICKUP`, `IN_DELIVERY`, `DELIVERED`, `FAILED`, `CANCELLED`, `RECOVERED`, `PENDING_APPROVAL`, `RECOVERING`.
2. THE `OrderStateMachine` SHALL enforce the following allowed transitions and no others:
   - `PENDING` → `ASSIGNED`, `CANCELLED`
   - `ASSIGNED` → `ACCEPTED`, `FAILED`, `PENDING`
   - `ACCEPTED` → `PREPARING`, `FAILED`
   - `PREPARING` → `READY_FOR_PICKUP`, `FAILED`
   - `READY_FOR_PICKUP` → `IN_DELIVERY`, `FAILED`
   - `IN_DELIVERY` → `DELIVERED`, `FAILED`
   - `FAILED` → `PENDING_APPROVAL`, `RECOVERED`, `CANCELLED`
   - `PENDING_APPROVAL` → `RECOVERING`, `CANCELLED`
   - `RECOVERING` → `RECOVERED`, `FAILED`
3a. WHEN a state transition is attempted, THE `OrderStateMachine` SHALL persist the new `Order` state within the same database transaction as the corresponding `AuditEvent` record, so that both succeed or both are rolled back atomically.
3b. WHEN a state transition is persisted, THE `OrderStateMachine` SHALL record an `AuditEvent` with the `from_state` and `to_state` values before returning success to the caller.
4. IF an invalid state transition is attempted, THEN THE `OrderStateMachine` SHALL raise an error whose message identifies both the attempted `from_state` and the attempted `to_state` values, and leave the `Order` state unchanged.
5. WHEN two concurrent transition attempts target the same `Order`, THE `OrderStateMachine` SHALL serialise them so that the second transition always observes the committed result of the first, with no lost updates.
6. THE `Order` model SHALL expose a method to retrieve the full list of `AuditEvent` records for that order by `order_id`, ordered by `occurred_at` ascending.
7. THE `OrderStateMachine` SHALL define `DELIVERED`, `CANCELLED`, and `RECOVERED` as terminal states from which no further transitions are permitted.

**Correctness Properties:**
- *Invariant*: An `Order` is never in more than one state at a time.
- *Invariant*: The set of allowed next states for any given state is finite, fixed, and derived exclusively from the transition table above.
- *Property*: Applying any invalid transition always leaves the `Order` record unchanged (`Order.state` before == `Order.state` after, verifiable by property test over all invalid `(from, to)` pairs).

---

### Requirement 2: Failure Event Creation and Injection

**User Story:** As an OrderOps operator, I want to record and inject order failure events, so that the recovery pipeline is triggered consistently whether a failure is natural or injected for demo purposes.

#### Acceptance Criteria

1. WHEN a failure condition is detected or injected, THE `FailureEvent` record SHALL be created with the following fields populated: `order_id`, `failure_type` (one of the nine defined enum values), `description`, `injected` (boolean), and `occurred_at`.
2. THE system SHALL support the following `failure_type` enum values: `RESTAURANT_REJECTION`, `RESTAURANT_UNAVAILABLE`, `INVENTORY_FAILURE`, `KITCHEN_DELAY`, `KITCHEN_FAILURE`, `DELIVERY_DELAY`, `DELIVERY_FAILURE`, `PAYMENT_FAILURE`, `EXTERNAL_SERVICE_FAILURE`.
3. THE `FailureInjector` SHALL provide an API method that accepts `(order_id, failure_type, description)` and creates a `FailureEvent` with `injected: true` and `occurred_at` set to `Time.current` at the moment of injection.
4. WHEN a `FailureEvent` is created via `FailureInjector`, THE system SHALL trigger the same `RecoveryOrchestrator` pipeline as a naturally occurring `FailureEvent`.
5. IF `FailureInjector.inject` is called against an `Order` whose state is `DELIVERED`, `CANCELLED`, `FAILED`, or `RECOVERED`, THEN THE `FailureInjector` SHALL raise `TerminalOrderError` and not create the `FailureEvent`.
6. WHEN a `FailureEvent` is created, THE system SHALL record an `AuditEvent` with `event_type: "failure_detected"` and `injected` flag set to match the `FailureEvent.injected` value.
7. WHEN the dashboard is viewing an active (non-terminal) order, THE dashboard SHALL expose a failure injection control to inject each of the nine failure types.
8. IF `FailureInjector.inject` is called with a `failure_type` value not in the nine-value enum, THEN THE system SHALL raise `InvalidFailureTypeError` and not create the `FailureEvent`.

**Correctness Properties:**
- *Invariant*: `FailureEvent.injected` is always explicitly set — never `nil`.
- *Property*: An injected `FailureEvent` and a naturally occurring `FailureEvent` of the same type on the same order produce identical downstream pipeline behaviour (verifiable by parallel property test comparing `AuditEvent` sequences).

---

### Requirement 3: AI-Assisted Failure Diagnosis (RecoveryAgent)

**User Story:** As an OrderOps operator, I want an AI agent to diagnose order failures and propose ranked recovery actions with reasoning, so that the system can respond quickly and consistently without requiring manual expert analysis for every failure.

#### Acceptance Criteria

1. WHEN a `FailureEvent` is received by the `RecoveryOrchestrator`, THE `RecoveryAgent` SHALL be invoked with a read-only context object containing: current `Order` state and metadata, the 50 most recent `AuditEvent` records for that order ordered by `occurred_at` ascending, `FailureEvent` type and description, list of permitted `RecoveryAction` types (pre-filtered by `PolicyConfig`), and current restaurant availability summary.
2. WHEN the `RecoveryAgent` returns successfully, THE response SHALL conform to a defined schema: a ranked array of at most 5 proposals, each containing `action_type`, `confidence` (Float, 0.0–1.0), `reasoning` (String), and `estimated_customer_impact` (`LOW`, `MEDIUM`, or `HIGH`).
3. THE `RecoveryAgent` SHALL propose only action types from the defined set: `REROUTE_RESTAURANT`, `PARTIAL_REFUND`, `FULL_REFUND`, `ISSUE_VOUCHER`, `ESCALATE_TO_HUMAN`, `CANCEL_ORDER`, `RETRY_DELIVERY`, `CONTACT_CUSTOMER`.
4. IF the AI provider call fails or exceeds the configurable timeout (default: 15 seconds), THEN THE `RecoveryAgent` SHALL apply the deterministic fallback strategy for the given `failure_type`, record an `AuditEvent` with `event_type: "ai_fallback"` and the fallback reason, and return a fallback output that conforms to the same response schema before being passed to the `PolicyEngine`.
5a. THE `RecoveryAgent` output SHALL be validated against the response schema before being passed to the `PolicyEngine`; IF validation fails, THEN THE `RecoveryAgent` SHALL apply the deterministic fallback strategy and return the fallback output.
5b. IF the fallback output itself fails schema validation, THEN THE `RecoveryOrchestrator` SHALL treat the result as an `ai_error` (see REQ-10 AC1) and not proceed to `PolicyEngine`.
6. THE `RecoveryAgent` SHALL NOT accept any tool, function, or method reference that mutates `Order` records, changes order state, executes refunds, calls `ActionExecutor`, bypasses `PolicyEngine`, or invokes simulator mutations.
7. WHEN the `RecoveryAgent` is invoked, THE system SHALL record an `AuditEvent` with `event_type: "ai_diagnosis"` whose `payload` includes the following fields: `failure_type`, `order_state`, `proposals_count`, and `ai_model`.
8. THE `RecoveryAgent` SHALL NOT include any of the following customer PII categories in the `reasoning` text stored in `AuditEvent` records: customer name, email address, phone number, or delivery address.
9. WHERE the `FakeProvider` is configured, THE `RecoveryAgent` SHALL return deterministic, pre-configured responses keyed by `failure_type`, enabling reproducible demo and test runs.

**Correctness Properties:**
- *Invariant*: The `RecoveryAgent` context object exposes only read methods; any write method call raises `NotImplementedError`.
- *Property*: For any given `(failure_type, order_state)` input pair, the `FakeProvider` always returns the same ranked proposal list (idempotence / determinism).
- *Property (round-trip)*: The structured AI response serialises to JSON and deserialises back to an equivalent object without data loss (catches schema drift early).

---

### Requirement 4: Deterministic Policy and Guardrail Engine

**User Story:** As an OrderOps platform owner, I want all recovery action proposals to pass through a deterministic, configuration-driven policy engine before any execution occurs, so that business rules are enforced consistently and are auditable regardless of what the AI recommends.

#### Acceptance Criteria

1. THE `PolicyEngine` SHALL evaluate every proposed `RecoveryAction` against all six guardrail rules before consulting `PolicyConfig`. If any guardrail rule fails, the action is `DENIED` immediately.
2. THE `PolicyEngine` SHALL enforce the following six guardrail rules:
   - **G1**: A refund amount may not exceed the `Order.total_cents` value.
   - **G2**: `FULL_REFUND` cannot be approved if the `Order` has any `AuditEvent` with `event_type: "partial_delivery_confirmed"`.
   - **G3**: `REROUTE_RESTAURANT` cannot be approved if the count of prior `REROUTE_RESTAURANT` `RecoveryAction` records with `status: "executed"` for the same order equals or exceeds the configurable `max_reroute_attempts` (default: 3).
   - **G4**: No action may be approved for an `Order` in a terminal state (`DELIVERED`, `CANCELLED`, `FAILED`, `RECOVERED`).
   - **G5**: `CANCEL_ORDER` requires either an `ApprovalRequest` in `approved` status or `allow_auto_cancel: true` set under the `cancel_order` policy block in `PolicyConfig`.
   - **G6**: If an `AuditEvent` with `event_type: "refund_executed"` already exists for the order, any further refund action (`PARTIAL_REFUND`, `FULL_REFUND`) is `DENIED` as a duplicate.
3. WHEN the `PolicyEngine` denies an action, THE `PolicyEngine` SHALL return a result object containing `status: "DENIED"` and a `reason` string that identifies the violated guardrail rule by its designated identifier (G1 through G6) or the specific policy clause violated.
4. WHEN the `PolicyEngine` approves an action without requiring human approval, THE `PolicyEngine` SHALL return `status: "APPROVED"` and `requires_human_approval: false`.
5. THE `PolicyEngine` SHALL determine that human approval is required when any of the following conditions is true:
   - Action is `FULL_REFUND` and `Order.total_cents` exceeds the configurable `human_approval_refund_threshold_cents` (default: 5000).
   - Action is `CANCEL_ORDER` and `Order.state` is one of `PREPARING`, `READY_FOR_PICKUP`, or `IN_DELIVERY`.
   - Count of prior `REROUTE_RESTAURANT` executions for the order is ≥ the configurable `human_approval_reroute_threshold` (default: 2).
   - The top-ranked AI `confidence` score is below the configurable `human_approval_confidence_threshold` (default: 0.5). IF the top-ranked proposal has no confidence score (`nil`), THE `PolicyEngine` SHALL treat it as `0.0`, triggering human approval.
   - `PolicyConfig` explicitly marks the `action_type` as `requires_approval: true`.
6. WHEN the `PolicyEngine` determines human approval is required, THE `PolicyEngine` SHALL return `status: "APPROVED"` and `requires_human_approval: true`.
7. THE `PolicyEngine` SHALL be a pure function: given identical inputs (`RecoveryAction` attributes, `Order` state snapshot, `AuditEvent` history, `PolicyConfig`), it always returns the same result.
8. `PolicyEngine.evaluate` SHALL perform no external I/O — no database reads, no HTTP calls, no file reads during evaluation. All required data is passed as arguments. `PolicyEngine.evaluate` SHALL return a result value object that includes all data needed for the caller to persist an `AuditEvent`; the recording of that `AuditEvent` is performed by the caller (`RecoveryOrchestrator`), not by `PolicyEngine`.
9. THE `RecoveryOrchestrator` SHALL record an `AuditEvent` with `event_type: "policy_evaluation"` and `policy_version` set to the `PolicyConfig.version` value, using the result object returned by `PolicyEngine.evaluate`.
10. THE `PolicyConfig` SHALL be defined in YAML, include a `version` string field, and be loaded once at startup. All numeric thresholds referenced above SHALL be read from `PolicyConfig`; no threshold value is hard-coded in application code. IF the `PolicyConfig` YAML cannot be loaded or parsed at startup, THE Rails application SHALL raise `PolicyConfig::LoadError` and refuse to start, including the expected file path and the parse error details in the exception message.

**Correctness Properties:**
- *Determinism property*: For any fixed set of inputs, `PolicyEngine.evaluate` returns the same result on every invocation (property test: run 100 times, assert all results equal).
- *Invariant*: `PolicyEngine.evaluate` never raises an unhandled exception; it always returns either `APPROVED` or `DENIED`.
- *Completeness property*: Every `(action_type, failure_type, order_state)` combination produces either `APPROVED`, `APPROVED with requires_human_approval`, or `DENIED` — no combination returns `nil` or raises (property test over exhaustive enum combinations).

---

### Requirement 5: Recovery Orchestration Pipeline

**User Story:** As an OrderOps operator, I want the system to automatically coordinate the full recovery sequence from failure detection through to action execution and state verification, so that recovery happens without requiring manual step-by-step orchestration.

#### Acceptance Criteria

1. WHEN a `FailureEvent` is created, THE `RecoveryOrchestrator` Solid Queue job SHALL be enqueued within 1 second.
2. WHEN the `RecoveryOrchestrator` job begins execution, THE orchestrator SHALL execute the pipeline steps in this order: invoke `RecoveryAgent` → validate output → invoke `PolicyEngine` on the highest-confidence proposal that passes `PolicyEngine` evaluation → route to approval gate or `ActionExecutor` → verify post-execution order state → record final `AuditEvent`.
3. WHEN the `PolicyEngine` returns `requires_human_approval: false`, THE `RecoveryOrchestrator` SHALL invoke `ActionExecutor` directly without creating an `ApprovalRequest`.
4. WHEN the `PolicyEngine` returns `requires_human_approval: true`, THE `RecoveryOrchestrator` SHALL create an `ApprovalRequest`, transition the `Order` to `PENDING_APPROVAL`, emit a Turbo Stream update to the approval queue panel, and halt until a human decision is received. IF no human decision is received within 72 hours, THE system SHALL transition the `Order` to `FAILED` and record an `AuditEvent` with `event_type: "approval_timeout_expired"`.
5. IF all proposed `RecoveryAction` candidates are denied by the `PolicyEngine`, OR if the `RecoveryAgent` returns zero proposals, THEN THE `RecoveryOrchestrator` SHALL create a `RecoveryAction` with `action_type: "ESCALATE_TO_HUMAN"` and transition the order to `PENDING_APPROVAL`.
6. THE `RecoveryOrchestrator` SHALL emit Turbo Stream updates to the recovery queue dashboard panel at each pipeline stage transition (diagnosis, policy decision, execution, completion).
7. WHEN the `RecoveryOrchestrator` completes successfully, THE `Order` SHALL be in `RECOVERED` state. An `Order` in `PENDING_APPROVAL` state is awaiting a human decision and is not yet complete.
8. IF `ActionExecutor` raises an error during execution, THEN THE `RecoveryOrchestrator` SHALL transition the `Order` to `FAILED`, record an `AuditEvent` with `event_type: "recovery_execution_failed"`, and not retry silently.
9. THE `RecoveryOrchestrator` SHALL record `AuditEvent` entries at each of the following pipeline stages: `recovery_started`, `ai_diagnosis`, `policy_evaluation`, `approval_requested` (if applicable), `action_executed`, `recovery_completed` or `recovery_failed`.
10. IF the `RecoveryAgent` output validation fails (per REQ-03 AC5a), THEN THE `RecoveryOrchestrator` SHALL apply the deterministic fallback strategy, record an `AuditEvent` with `event_type: "ai_validation_error"`, and continue the pipeline with the fallback proposals.

**Correctness Properties:**
- *Invariant*: The `RecoveryOrchestrator` never calls `ActionExecutor` without a preceding `PolicyEngine` `APPROVED` result recorded in `AuditEvent`.
- *Invariant*: The `RecoveryOrchestrator` never calls `ActionExecutor` for a `requires_human_approval: true` result unless an `ApprovalRequest` with `status: "approved"` exists.

---

### Requirement 6: Action Executor and In-Process Simulators

**User Story:** As an OrderOps operator, I want approved recovery actions to be executed reliably against in-process simulators, so that the full recovery lifecycle can be demonstrated end-to-end without external API dependencies.

#### Acceptance Criteria

1. THE `ActionExecutor` SHALL support execution of all eight `RecoveryAction` types: `REROUTE_RESTAURANT`, `PARTIAL_REFUND`, `FULL_REFUND`, `ISSUE_VOUCHER`, `ESCALATE_TO_HUMAN`, `CANCEL_ORDER`, `RETRY_DELIVERY`, `CONTACT_CUSTOMER`.
2a. THE `ActionExecutor` SHALL only be invoked by `RecoveryOrchestrator`.
2b. IF `ActionExecutor` is invoked from any caller other than `RecoveryOrchestrator`, THEN `ActionExecutor` SHALL raise `UnauthorizedCallError` and not execute.
3. WHEN `ActionExecutor` executes `REROUTE_RESTAURANT`, THE system SHALL query the `RestaurantSimulator` for an available restaurant that meets the cuisine type requirement, assign it to the `Order`, and call `order.transition_to!(:assigning)` to restart the restaurant assignment flow.
4. WHEN `ActionExecutor` executes `FULL_REFUND`, THE system SHALL call `PaymentSimulator.refund(amount_cents: order.total_cents)` and record the result in an `AuditEvent`.
5. WHEN `ActionExecutor` executes `PARTIAL_REFUND`, THE system SHALL call `PaymentSimulator.refund(amount_cents: recovery_action.parameters.fetch(:amount_cents))` and record the result in an `AuditEvent`.
6. THE `RestaurantSimulator` SHALL support: a configurable `acceptance_rate` (Float, 0.0–1.0), a configurable `latency_ms` (Integer, 1–5000), marking a restaurant as unavailable, and a method to return a ranked list of available restaurants by cuisine type ordered by acceptance rate descending.
7. THE `PaymentSimulator` SHALL support: processing a refund of a given amount, configurable success/failure rate, and returning a transaction reference on success.
8. WHEN `ActionExecutor` completes execution, THE `RecoveryAction` `status` SHALL be updated to `executed` and `executed_at` SHALL be set.
9. IF the simulator call raises an error, THEN `ActionExecutor` SHALL update `RecoveryAction.status` to `failed`, record the error in an `AuditEvent`, and re-raise the error to `RecoveryOrchestrator`.
10. THE `RestaurantSimulator` SHALL exclude from reroute candidates any restaurant that has already rejected the same order (tracked via `AuditEvent` records with `event_type: "restaurant_rejected"`).
11. THE `ActionExecutor` SHALL handle `ISSUE_VOUCHER`, `CANCEL_ORDER`, `RETRY_DELIVERY`, `CONTACT_CUSTOMER`, and `ESCALATE_TO_HUMAN` by calling their respective in-process simulator stubs: `VoucherSimulator`, `CancellationSimulator`, `DeliverySimulator`, and `NotificationSimulator`. Each simulator SHALL return a success/failure result that `ActionExecutor` records in an `AuditEvent`.
12. IF `RestaurantSimulator` returns no restaurants matching the order's cuisine type for a `REROUTE_RESTAURANT` action, THEN `ActionExecutor` SHALL raise `NoRestaurantAvailableError`; THE `RecoveryOrchestrator` SHALL catch this error and proceed to the next ranked proposal.

---

### Requirement 7: Human Approval Workflow

**User Story:** As an OrderOps operator, I want to review and approve or reject high-risk recovery actions from the dashboard before they execute, so that the system never automatically performs irreversible financial operations above the configured threshold without my explicit sign-off.

#### Acceptance Criteria

1. WHEN an `ApprovalRequest` is created, THE `ApprovalRequest` record SHALL be set to `status: "pending"` with `requested_at` populated and `decided_at` left null.
2. WHEN an `ApprovalRequest` is created, THE dashboard approval queue panel SHALL receive a Turbo Stream update displaying: `order_id`, `failure_type`, AI diagnosis summary, proposed `action_type`, `ai_confidence` score, and elapsed wait time.
3. WHEN an operator approves an `ApprovalRequest` from the dashboard, THE system SHALL set `ApprovalRequest.status` to `"approved"`, set `operator_id` and `decided_at`, record an `AuditEvent` with `event_type: "human_approval_received"`, and resume the `RecoveryOrchestrator` pipeline.
4. WHEN an operator rejects an `ApprovalRequest` from the dashboard, THE system SHALL set `ApprovalRequest.status` to `"rejected"`, set `operator_id`, `operator_note`, and `decided_at`, record an `AuditEvent` with `event_type: "human_approval_rejected"`, and transition the `Order` to `FAILED`.
5a. THE system SHALL enforce that at most one `ApprovalRequest` per `Order` is in `status: "pending"` at any time.
5b. IF a second `ApprovalRequest` is created for an `Order` that already has one in `status: "pending"`, THEN THE system SHALL raise `DuplicateApprovalRequestError` and not create the second record.
6. THE `ActionExecutor` SHALL NOT execute a `FULL_REFUND` action unless an `ApprovalRequest` with `status: "approved"` and matching `recovery_action_id` exists in the database. IF `ActionExecutor` is called for `FULL_REFUND` and no such matching `ApprovalRequest` exists, THEN `ActionExecutor` SHALL raise `ApprovalRequiredError` and log the attempt.
7. WHEN an `ApprovalRequest` has been pending for longer than the configurable `approval_timeout_seconds` (default: 120, minimum: 30, maximum: 86400), THE system SHALL emit an escalation `AuditEvent` with `event_type: "approval_timeout"` and leave the order in `PENDING_APPROVAL` state for continued operator visibility.
8. IF the `Order` is no longer in `PENDING_APPROVAL` state when an operator submits an approval decision (e.g., it was concurrently cancelled), THEN THE system SHALL return an error response to the operator and SHALL NOT invoke `ActionExecutor`.

**Correctness Properties:**
- *Invariant*: At most one `ApprovalRequest` per `Order` has `status: "pending"` at any point in time (database unique index on `[order_id, status]` where `status = "pending"`, verifiable by property test inserting concurrent requests).

---

### Requirement 8: Complete Audit Trail

**User Story:** As an OrderOps operator, I want every meaningful system event recorded immutably in a per-order audit log, so that I can reconstruct the complete history of any order's recovery journey for review, compliance, or debugging.

#### Acceptance Criteria

1. THE `AuditEvent` record SHALL include the following fields: `id`, `order_id`, `event_type`, `actor_type` (`system`, `ai`, `human`, `simulator`), `actor_id`, `from_state`, `to_state`, `payload` (jsonb), `policy_version`, `ai_model`, `injected` (boolean), `occurred_at` (UTC, millisecond precision). The `event_type` field SHALL be one of the following exhaustive enum values: `order_state_changed`, `failure_detected`, `recovery_started`, `ai_diagnosis`, `ai_fallback`, `ai_error`, `ai_validation_error`, `policy_evaluation`, `approval_requested`, `human_approval_received`, `human_approval_rejected`, `approval_timeout`, `approval_timeout_expired`, `action_executed`, `execution_error`, `recovery_completed`, `recovery_failed`, `orchestration_exhausted`, `escalated_to_human`. The `policy_version` field SHALL be NULL for all events other than `policy_evaluation`. The `ai_model` field SHALL be NULL for all events other than `ai_diagnosis` and `ai_fallback`.
2. THE audit trail SHALL record `AuditEvent` entries for every: order state transition, `FailureEvent` creation, `RecoveryAgent` invocation, `PolicyEngine` evaluation, `ApprovalRequest` creation, human approval or rejection, `ActionExecutor` execution (success or failure).
3. THE `AuditEvent` table SHALL have no `UPDATE` or `DELETE` path in application code; records are append-only.
4. WHEN an `AuditEvent` is created for a `PolicyEngine` evaluation, THE `AuditEvent.policy_version` field SHALL be set to the `PolicyConfig.version` value active at evaluation time.
5. WHEN an `AuditEvent` is created for a `RecoveryAgent` invocation, THE `AuditEvent.ai_model` field SHALL be set to the provider model name, and `payload` SHALL include the input context summary and structured output.
6. WHEN a retrieval query is executed for a given `order_id`, THE `AuditEvent` records SHALL be returned ordered by `occurred_at` ascending.
7a. WHEN an operator selects an order in the dashboard, THE Audit Timeline panel SHALL render the full ordered list of `AuditEvent` records for that order by `occurred_at` ascending.
7b. WHEN a new `AuditEvent` is appended for an order whose Audit Timeline is currently displayed, THE Audit Timeline panel SHALL receive a Turbo Stream update within 5 seconds.
8. IF an `AuditEvent` is created as a direct result of a `FailureInjector.inject` call, THEN `AuditEvent.injected` SHALL be `true`. Cascading downstream events triggered by that failure (e.g., `ai_diagnosis`, `policy_evaluation`, `action_executed`) SHALL have `injected: false`.

**Correctness Properties:**
- *Append-only invariant*: The count of `AuditEvent` records for any `order_id` is monotonically non-decreasing over time (property test: record count before and after any operation, assert count after ≥ count before).
- *Round-trip property*: `AuditEvent.payload` serialises to JSON and deserialises to an equivalent Ruby hash without data loss (guards against jsonb encoding bugs).

---

### Requirement 9: Real-Time Dashboard

**User Story:** As an OrderOps operator, I want a real-time web dashboard showing active order states, failure events, recovery activity, and pending approvals, so that I can monitor system health and intervene when required without manually refreshing the page.

#### Acceptance Criteria

1. THE dashboard SHALL display the following panels: Order Stream, Failure Feed, Recovery Queue, Approval Queue, Audit Timeline.
2. WHEN any `Order` state changes, THE Order Stream panel SHALL update via Turbo Stream within 2 seconds without a full page reload.
3. WHEN a `FailureEvent` is created, THE Failure Feed panel SHALL display a new entry with: `order_id`, `failure_type`, `injected` flag, and `occurred_at` — updated via Turbo Stream.
4. WHEN a `RecoveryOrchestrator` pipeline stage completes, THE Recovery Queue panel SHALL update via Turbo Stream to reflect the current stage, AI diagnosis summary, and proposed action.
5. WHEN an `ApprovalRequest` enters `status: "pending"`, THE Approval Queue panel SHALL display it with: `order_id`, `failure_type`, AI reasoning, proposed action, `ai_confidence` score, and a running elapsed-time indicator.
6. THE Approval Queue panel SHALL provide Approve and Reject buttons for each pending `ApprovalRequest`; submitting either SHALL trigger the human approval workflow (REQ-07) without a full page reload.
7. WHEN an operator selects an order in the dashboard, THE Audit Timeline panel SHALL display the full ordered `AuditEvent` sequence for that order and update via Turbo Stream as new events arrive.
8. THE Order Stream panel SHALL display each active order with: `order_id`, current `state`, failure type (if any), and recovery status (if in recovery pipeline).
9. THE dashboard SHALL expose a failure injection control per active order that posts to the `FailureInjector` API and triggers the full pipeline.

---

### Requirement 10: Error Handling and Resilience

**User Story:** As an OrderOps platform owner, I want every failure path in the recovery pipeline to be handled explicitly, so that the system never silently drops an error, leaves an order in an indeterminate state, or exposes an unhandled exception to the operator.

#### Acceptance Criteria

1. IF `RecoveryAgent` raises an unhandled exception, THEN THE `RecoveryOrchestrator` SHALL catch the exception, apply the deterministic fallback strategy, and record an `AuditEvent` with `event_type: "ai_error"` and the exception message.
2. IF `PolicyEngine.evaluate` raises an unhandled exception, THEN THE `RecoveryOrchestrator` SHALL transition the `Order` to `FAILED`, record an `AuditEvent` with `event_type: "policy_error"`, and not proceed to `ActionExecutor`.
3. IF `ActionExecutor` raises an unhandled exception during simulator call, THEN THE `RecoveryOrchestrator` SHALL transition the `Order` to `FAILED`, set `RecoveryAction.status` to `"failed"`, and record an `AuditEvent` with `event_type: "execution_error"`.
4. WHEN a Solid Queue job for `RecoveryOrchestrator` fails after all retries are exhausted, THE system SHALL leave the `Order` in its last known valid state and record a final `AuditEvent` with `event_type: "orchestration_exhausted"`.
5. IF a `RestaurantSimulator` returns no available restaurants matching the order's cuisine type, THEN THE `ActionExecutor` SHALL return a `NO_RESTAURANT_AVAILABLE` result, the `RecoveryOrchestrator` SHALL move to the next ranked `RecoveryAction` proposal, and if no further proposals exist, SHALL escalate to human approval.
6. THE `PolicyEngine` SHALL never raise an unhandled exception; it SHALL always return either an `APPROVED` or `DENIED` result object, catching and wrapping any internal errors as `DENIED` with `reason: "internal_policy_error"`.
7. IF the `PolicyConfig` YAML file is missing or unparseable at startup, THEN THE Rails application SHALL fail to boot with a descriptive error message identifying the missing or invalid configuration.

---

## Demo Scenarios as Acceptance Tests

These two scenarios serve as end-to-end acceptance tests for the complete pipeline. Both must be executable as RSpec system specs against a running Rails test environment with `FakeProvider` configured.

### Demo Scenario 1 — Automatic Restaurant Reroute

**Preconditions:**
- An `Order` exists in `PREPARING` state with `total_cents: 2500` (below human approval threshold).
- `PolicyConfig` has `max_reroute_attempts: 3`, `human_approval_reroute_threshold: 2`.
- `FakeProvider` is configured to respond to `KITCHEN_FAILURE` with proposal `REROUTE_RESTAURANT` at `confidence: 0.85`.
- `RestaurantSimulator` has at least one available restaurant matching the order's cuisine type.

**Steps and Assertions:**

1. Operator triggers failure injection: `FailureInjector.inject(order_id: order.id, failure_type: "KITCHEN_FAILURE", description: "Kitchen equipment failure")`.
2. Assert: `FailureEvent` created with `injected: true`, `failure_type: "KITCHEN_FAILURE"`.
3. Assert: `RecoveryOrchestrator` job is enqueued.
4. After job execution, assert: `RecoveryAgent` was invoked and an `AuditEvent` with `event_type: "ai_diagnosis"` exists.
5. Assert: `PolicyEngine` evaluated `REROUTE_RESTAURANT` and produced `APPROVED` with `requires_human_approval: false` (reroute count = 0, below threshold; confidence = 0.85, above threshold; order total below refund threshold).
6. Assert: No `ApprovalRequest` was created.
7. Assert: `ActionExecutor` executed `REROUTE_RESTAURANT` and `RecoveryAction.status` is `"executed"`.
8. Assert: `Order.state` is `RECOVERING` or `RECOVERED`.
9. Assert: `AuditEvent` sequence for the order contains, in order: `failure_detected`, `recovery_started`, `ai_diagnosis`, `policy_evaluation`, `action_executed`, `recovery_completed`.
10. Assert: The dashboard Recovery Queue panel received a Turbo Stream broadcast.

### Demo Scenario 2 — Human Approval for Full Refund

**Preconditions:**
- An `Order` exists in `IN_DELIVERY` state with `total_cents: 7500` (above $50 threshold — 5000 cents).
- `PolicyConfig` has `human_approval_refund_threshold_cents: 5000`.
- `FakeProvider` is configured to respond to `DELIVERY_FAILURE` with proposal `FULL_REFUND` at `confidence: 0.90`.

**Steps and Assertions:**

1. `FailureEvent` is created with `failure_type: "DELIVERY_FAILURE"`, `injected: true`.
2. After `RecoveryOrchestrator` job execution, assert: `PolicyEngine` evaluated `FULL_REFUND` and returned `APPROVED` with `requires_human_approval: true` (order total 7500 > threshold 5000).
3. Assert: `ApprovalRequest` created with `status: "pending"`.
4. Assert: `Order.state` is `PENDING_APPROVAL`.
5. Assert: No `ActionExecutor` call has occurred at this point (verify by checking no `RecoveryAction` with `status: "executed"` exists and no `PaymentSimulator` was invoked).
6. Assert: Approval Queue panel received a Turbo Stream broadcast with the pending request.
7. Operator submits approval via dashboard action: `POST /approval_requests/:id/approve`.
8. Assert: `ApprovalRequest.status` is `"approved"`, `decided_at` is set.
9. Assert: `ActionExecutor` executed `FULL_REFUND`, `PaymentSimulator` was called with `amount_cents: 7500`.
10. Assert: `Order.state` is `RECOVERED`.
11. Assert: `AuditEvent` sequence contains, in order: `failure_detected`, `recovery_started`, `ai_diagnosis`, `policy_evaluation`, `approval_requested`, `human_approval_received`, `action_executed`, `recovery_completed`.

---

## Safety Requirements

These requirements enforce the AI advisory-only boundary and are non-negotiable. They must be verified by code review and automated tests.

### Requirement 11: AI Advisory Boundary Enforcement

**User Story:** As an OrderOps platform owner, I want the AI boundary to be enforced at the type and interface level, so that no code path allows the AI agent to directly mutate order state, execute financial operations, or bypass the policy engine.

#### Acceptance Criteria

1. THE `RecoveryAgent` context object passed to the AI SHALL expose only read-only methods; any method that mutates an `Order`, `RecoveryAction`, `AuditEvent`, or calls a simulator SHALL raise `NotImplementedError` when invoked.
2. THE `RecoveryAgent` SHALL have no `ActiveRecord` write access; all database interactions SHALL be via read-only query objects or presenter objects with no `save`, `update`, `create`, or `destroy` methods.
3. THE `ActionExecutor` SHALL verify that a valid `PolicyEngine` approval result is present in `AuditEvent` before executing any action; IF no approval record is found, THEN THE `ActionExecutor` SHALL raise `PolicyBypassError` and not execute.
4. THE system SHALL include an RSpec shared example group `"AI advisory boundary"` that is included in all `RecoveryAgent` specs, asserting that none of the write methods can be invoked from the agent context.
5. THE `RecoveryAgent` SHALL be instantiated in a separate object scope that does not hold a reference to `ActionExecutor`, `OrderStateMachine` transition methods, or any simulator mutation method.

---

## Non-Goals

The following are explicitly out of scope for this feature and must not be implemented:

| Item | Reason |
|---|---|
| Real restaurant, payment, inventory, or delivery API integrations | Simulators only; no external API dependencies |
| Redis, Kafka, or Sidekiq | Solid Queue and Solid Cable are the only permitted background/async infrastructure |
| React, Vue, or any separate SPA | Hotwire/Turbo only; no separate frontend build step |
| Predictive SLA breach detection | Nice-to-have; out of scope for V1 |
| Multi-agent AI chains or parallel agent calls | Single structured LLM call only for V1 |
| Customer-facing UI | Operator-facing dashboard only |
| Payment processing beyond simulator | No real payment gateway integration |
| Production deployment, scaling, or infrastructure provisioning | Demo environment only |
| LLM provider switching at runtime | Provider is configured at startup; runtime switching is not supported in V1 |
| Policy hot-reload without restart | `PolicyConfig` is loaded once at boot; live reload is a future enhancement |
| Recovery action idempotency across process restarts | Known V1 gap; documented and mitigated by G6 duplicate refund guardrail |

---

## Non-Functional Requirements

### NFR-01 — Testability
- Each subsystem (`OrderStateMachine`, `FailureInjector`, `RecoveryAgent`, `PolicyEngine`, `RecoveryOrchestrator`, `ActionExecutor`, `AuditEvent`) SHALL be independently unit-testable with RSpec and FactoryBot.
- The `PolicyEngine` SHALL have 100% branch coverage across all six guardrail rules and all five human-approval triggers.
- Both demo scenarios SHALL have corresponding RSpec system specs that execute the full pipeline end-to-end.

### NFR-02 — Configurability
- All numeric thresholds (`max_reroute_attempts`, `human_approval_refund_threshold_cents`, `human_approval_reroute_threshold`, `human_approval_confidence_threshold`, `approval_timeout_seconds`, AI timeout) SHALL be sourced from `PolicyConfig` YAML.
- No business rule value SHALL be hard-coded as a literal in application code.

### NFR-03 — No Magic Numbers
- All constants used in business logic SHALL be referenced via named `PolicyConfig` keys.
- An RSpec shared example SHALL verify that no numeric literal appears in `PolicyEngine`, `RecoveryOrchestrator`, or `ActionExecutor` source files outside of test fixtures.

### NFR-04 — Extensibility
- Adding a new `failure_type` SHALL require changes to at most three files: the `failure_type` enum definition, the `PolicyConfig` YAML default, and the `FakeProvider` response map.
- Adding a new `action_type` SHALL require changes to at most three files: the `action_type` enum definition, the `PolicyConfig` YAML default, and the `ActionExecutor` dispatch table.
