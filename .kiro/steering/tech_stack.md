# Tech Stack

This project uses the following technologies. All code generation must target these versions and libraries — do not introduce alternatives without explicit approval.

## Framework
- **Ruby on Rails 8.1**

## Database
- **PostgreSQL**

## Background Jobs
- **Solid Queue** — for async job processing
- **Solid Cable** — for WebSocket / Action Cable backend

## Frontend
- **Hotwire** — Turbo Streams & Stimulus
- No React, Vue, or other JS frameworks unless explicitly requested

## State Machine
- **AASM** — all order/workflow state machines use AASM

## Testing
- **RSpec** — primary test framework
- **Rantly** — property-based testing for domain logic (PolicyEngine, RecoveryContext, etc.)
