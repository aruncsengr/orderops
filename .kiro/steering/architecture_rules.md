# Architecture Rules

These are non-negotiable constraints for this project. All code generation, refactoring, and design decisions must respect these rules. Any implementation that violates them is a defect.

## AI Advisory Boundary
- AI is strictly **advisory** — it may analyze, recommend, and propose recovery actions.
- AI **cannot** mutate ActiveRecord models or execute side effects directly.
- All mutations flow through ActionExecutor after explicit policy authorization.

## RecoveryContext
- Must be built as a **deeply frozen Ruby `Data` object** (use `Data.define` on Ruby >= 3.2, or a frozen `Struct` on earlier versions).
- May contain **primitive values and plain hashes only** — no ActiveRecord model references, no `method_missing` delegation.
- Represents an immutable **snapshot** of order state at context-creation time.

## PolicyEngine
- Must be a **pure function**: zero I/O, zero database access, fully deterministic.
- Given the same inputs it must always return the same output.
- No side effects of any kind — no logging, no enqueuing, no DB reads.

## ActionExecutor Verification
- Before executing any recovery action, ActionExecutor **must** query `AuditEvent` records for an authorization entry matching the exact tuple:
  `(order_id, recovery_action_id, policy_config_version)`
- If no matching record exists, raise `PolicyBypassError` immediately.
- No fallback, no soft failure, no skipping in test environments.

## AuditEvent Immutability
- `AuditEvent` records are **append-only**.
- No updates or deletes are permitted — enforce at the model level with `before_update` and `before_destroy` callbacks that raise unconditionally.

## State Machine Transitions
- All AASM state transitions on orders **must** be wrapped in a PostgreSQL row lock: call `order.lock!` before transitioning.
- This prevents race conditions when multiple processes attempt concurrent state changes on the same order.
