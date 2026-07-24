# Spec: Feedback (P2)

Covers the thumbs up/down + optional comment widget on the results page. Lower priority than the other specs (P2 in the PRD) — schema and API are included now so Stage 2's SQL is complete, but this UI can ship after the core review + chat flow.

## User Flow

On the results page, user clicks a thumbs-up or thumbs-down icon, optionally adds a comment, and submits → `POST /api/contracts/[id]/feedback` upserts the feedback → widget shows a brief confirmation ("Thanks for your feedback") and reflects the submitted rating as selected. Re-submitting (e.g. changing from 👍 to 👎) updates the existing record rather than creating a duplicate.

## DB Schema

Relevant columns (full definition in `docs/specs/supabase-schema.sql`): `user_feedback(id, user_id, contract_id, rating, comment, created_at)`, with a `unique (user_id, contract_id)` constraint — one feedback record per user per contract, enabling upsert semantics.

## DB Tasks

`INSERT INTO user_feedback (...) ON CONFLICT (user_id, contract_id) DO UPDATE SET rating = excluded.rating, comment = excluded.comment`.

## API Routes

### `POST /api/contracts/[id]/feedback`
- **Auth:** required; ownership check on the contract.
- **Request:** `{ "rating": "up" | "down", "comment"?: string }` (`comment` ≤ 1000 chars).
- **Response 201:** `{ "feedback_id": string }`.
- **Behavior:** upsert on `(user_id, contract_id)` — see DB Tasks.
- **Errors:** `404 contract_not_found`.

### `GET /api/contracts/[id]/feedback` (optional, to pre-populate the widget on page load)
- **Auth:** required; ownership check.
- **Response 200:** `{ "feedback": { "rating": "up" | "down", "comment": string | null } | null }`.

## State Management

`useFeedback(contractId)` — React Query for the existing feedback (if any), key `["feedback", contractId]`. `useSubmitFeedback(contractId)` — mutation, optimistically marks the clicked icon as selected.

## Component Spec

- `<FeedbackWidget rating, comment, onSubmit>` — two icon toggle buttons (👍/👎, mutually exclusive) + an optional, initially-collapsed comment textarea revealed after a rating is picked + a "Submit" button.

## Design

Icon buttons use the design system's interactive/hover states; the selected state uses the brand primary colour, not a raw green/red (this is sentiment feedback, not a confidence or status signal, so it must not share the confidence-badge colour vocabulary).

## Edge Cases

- User submits feedback twice with different ratings → second submission overwrites the first (upsert), no duplicate rows possible due to the unique constraint.
- Comment submitted without a rating → rejected client-side (rating is required to submit; comment alone is not accepted).
- Contract belongs to another user → `404` (never `403`, to avoid confirming the contract's existence to a non-owner).

## Acceptance Criteria

- [ ] A thumbs up/down rating with an optional comment can be submitted from the results page and is saved to `user_feedback` (US-010, FR-12).
- [ ] Submitting feedback twice for the same contract updates the existing record rather than creating a duplicate (enforced by the `unique(user_id, contract_id)` constraint).
- [ ] A comment cannot be submitted without a rating.
- [ ] Requesting or submitting feedback for a contract owned by another user returns `404`.
