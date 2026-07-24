# Spec: Dashboard

Covers the authenticated landing page: summary counts, breakdown by contract type, and a sortable list of past contracts.

## User Flow

User signs in → `/dashboard` → `GET /api/dashboard` loads summary + list → empty state ("No contracts reviewed yet — upload your first contract to begin") if the user has zero contracts, otherwise a summary card (total contracts, NDA/MSA breakdown) plus a sortable table of contracts. Clicking a row navigates to `/contracts/[id]` (results view). A prominent "Review a Contract" CTA navigates to `/contracts/new` (upload screen) from either state.

## DB Schema

Relevant columns (full definitions in `docs/specs/supabase-schema.sql`): `contracts(id, contract_type, file_name, status, created_at)`, scoped to `auth.uid()` via RLS.

## DB Tasks

Read-only. `SELECT id, file_name, contract_type, status, created_at FROM contracts WHERE user_id = auth.uid() ORDER BY <sort column> <order>` plus an aggregate `SELECT contract_type, count(*) FROM contracts WHERE user_id = auth.uid() GROUP BY contract_type` for the summary card.

## API Routes

### `GET /api/dashboard`
- **Auth:** required.
- **Query params:** `sort` (`"date" | "name" | "type"`, default `"date"`), `order` (`"asc" | "desc"`, default `"desc"`).
- **Response 200:**
  ```json
  {
    "total_contracts": 12,
    "by_type": { "NDA": 7, "MSA": 5 },
    "contracts": [
      { "id": "...", "file_name": "vendor-nda.pdf", "contract_type": "NDA", "status": "complete", "created_at": "..." }
    ]
  }
  ```
- **Errors:** none beyond standard `401` — this route has no user-supplied resource to look up.

## State Management

`useDashboard(sort, order)` — React Query, key `["dashboard", sort, order]`, refetched on sort/order change and invalidated whenever a new contract is uploaded or finishes processing (invalidate `["dashboard"]` broadly from the upload/process mutations).

## Component Spec

- `<DashboardSummaryCard totalContracts, byType>` — total count + a small breakdown (e.g. "7 NDA · 5 MSA").
- `<ContractsTable contracts, sort, order, onSortChange>` — sortable columns (Name, Type, Date, Status); each row clickable, `status='error'` rows show a "Retry" button that calls `POST /api/contracts/[id]/process` directly from the dashboard (per the AI-extraction spec's retry-from-error behavior) instead of navigating away.
- `<DashboardEmptyState>` — copy: "No contracts reviewed yet — upload your first contract to begin," with the "Review a Contract" CTA.
- `<ReviewContractCTA>` — shared button linking to `/contracts/new`, shown in both the empty and populated states.

## Design

Table rows and the summary card follow `docs/design.md` spacing/typography tokens; status badges (`complete`/`processing`/`error`) reuse the same badge component family as `<ConfidenceBadge>` from the results viewer for visual consistency, with distinct semantic colours (not confidence-score colours).

## Edge Cases

- Zero contracts → empty state, no table/summary card rendered.
- A contract stuck in `status='processing'` (e.g. the user navigated away mid-extraction) → shown with a "Processing..." badge; the dashboard does not auto-poll, but revisiting the dashboard after processing genuinely completes shows the updated status on next fetch/refetch.
- A contract in `status='error'` → shown with an "Error" badge + inline "Retry" action (no re-upload required, since `contract_text` is already stored).
- Very long `file_name` → truncated with an ellipsis and a title attribute for the full name on hover.

## Acceptance Criteria

- [ ] The dashboard shows total contracts reviewed and a breakdown by type (NDA/MSA) (US-008, FR-10).
- [ ] The contract list is sortable by name, type, date, and status; clicking any row opens that contract's results page.
- [ ] A first-time user with zero contracts sees the empty state, not an empty table.
- [ ] A contract in `status='error'` shows an inline "Retry" action that re-triggers processing without requiring re-upload.
- [ ] Only the authenticated user's own contracts are ever returned — verified by the RLS cross-user-access test in the testing strategy.
