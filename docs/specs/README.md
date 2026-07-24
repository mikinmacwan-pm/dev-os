# ContractIQ — Implementation Specification

This is the comprehensive implementation specification for ContractIQ, generated from `docs/engineering/engineering-doc.md` per `skills/implementation-specs/SKILL.md`. It indexes every feature spec, the database schema, the environment configuration, and the cross-cutting technical requirements in one place. Each linked file is self-contained and runnable on its own; this page is the map between them.

**Companion documents:**
- `docs/ContractIQ_PRD.md` — original product requirements (user stories US-001…US-012, functional requirements FR-01…FR-14)
- `docs/engineering/engineering-doc.md` — architecture, AI provider rationale, full API/DB design (Stage 1)
- `docs/engineering/implementation-specs.md` — per-feature overview blocks (Stage 1)
- `docs/design.md` — brand design system (colors, typography, spacing) — apply via `/design-system` to every UI change in Stage 4

---

## Technical Requirements

**[`technical-requirements.md`](./technical-requirements.md)** — performance budgets, upload/document limits, cost targets, scalability, reliability, security & compliance requirements, accessibility, and the AI provider constraints that apply across every feature below.

## Database

**[`supabase-schema.sql`](./supabase-schema.sql)** — paste-and-run SQL: enums, all 6 tables, the `term_corrections` view, `updated_at` triggers, RLS policies on every table, and the `contracts` Storage bucket + its RLS policies.

| Table | Purpose |
|---|---|
| `contracts` | One row per uploaded contract — type, extracted text (with `[PAGE N]` markers), Storage path, processing status |
| `key_terms` | One row per extracted (or custom) term — value, page, confidence, source sentence, edit history |
| `custom_key_terms` | User-defined term names requested pre-processing (max 5 per contract) |
| `chat_sessions` | One session per contract |
| `chat_messages` | Chat turns — role, content, page citation |
| `user_feedback` | Thumbs up/down + comment per contract, upserted per user |
| `term_corrections` (view) | `key_terms` filtered to `is_edited = true` — feeds the ≤12%-correction-rate monitoring |

## Environment

**[`../../contractiq/.env.local.example`](../../contractiq/.env.local.example)** — every environment variable the app needs (Supabase, Anthropic, rate limiting, app URL), grouped and annotated.

---

## Features

Each spec follows the same shape: User Flow → DB Schema → DB Tasks → API Routes → State Management → Component Spec → Design → Edge Cases → **Acceptance Criteria**.

| # | Feature | Spec | Priority | Depends on |
|---|---|---|---|---|
| 1 | Authentication | [`auth.md`](./auth.md) | P0 | — |
| 2 | Contract Upload & Text Extraction | [`contract-upload.md`](./contract-upload.md) | P0 | Auth |
| 3 | AI Key-Term Extraction | [`ai-key-term-extraction.md`](./ai-key-term-extraction.md) | P0 | Contract Upload |
| 4 | Results Viewer (PDF/Text Viewer + Key Terms Panel) | [`results-viewer.md`](./results-viewer.md) | P0/P1 | AI Key-Term Extraction |
| 5 | Contract Chat | [`contract-chat.md`](./contract-chat.md) | P1 | AI Key-Term Extraction |
| 6 | Dashboard | [`dashboard.md`](./dashboard.md) | P1 | Auth, Contract Upload |
| 7 | Feedback | [`feedback.md`](./feedback.md) | P2 | Results Viewer |

This is also the recommended Stage 4 build order — each feature's spec assumes the ones above it in the table already exist.

---

## API Reference (consolidated)

All routes require a valid Supabase session unless noted; every error response shares the shape `{ "error": { "code": string, "message": string } }`.

| Method | Path | Feature | Purpose |
|---|---|---|---|
| `POST` | `/api/contracts/upload` | Contract Upload | Upload a PDF, extract text, create the `contracts` row |
| `POST` | `/api/contracts/[id]/custom-terms` | Contract Upload | Register up to 5 custom key terms pre-processing |
| `POST` | `/api/contracts/[id]/process` | AI Key-Term Extraction | Trigger Claude extraction, persist `key_terms` |
| `GET` | `/api/contracts/[id]` | Results Viewer | Fetch contract + key terms + viewer data (PDF signed URL or text fallback) |
| `PATCH` | `/api/contracts/[id]/key-terms/[termId]` | Results Viewer | Inline-edit an extracted term's value |
| `POST` | `/api/contracts/[id]/chat` | Contract Chat | Send a chat message, get a grounded Claude response |
| `GET` | `/api/contracts/[id]/chat` | Contract Chat | Load the persisted chat session |
| `GET` | `/api/dashboard` | Dashboard | Summary counts + sortable contract list |
| `POST` | `/api/contracts/[id]/feedback` | Feedback | Submit thumbs up/down + optional comment (upsert) |
| `GET` | `/api/contracts/[id]/feedback` | Feedback | Pre-populate the feedback widget |

These map 1:1 to the route stubs already scaffolded under `contractiq/app/api/` (Stage 3) — each currently returns `501 not_implemented` with a pointer to its spec, to be replaced with real logic feature-by-feature in Stage 4.

---

## Success Metrics (from the PRD — what "done" means)

| Metric | Target |
|---|---|
| Time from upload to completed review | ≤ 15 minutes end-to-end |
| Key-term extraction accuracy | ≥ 88% F1 (NDA), ≥ 85% F1 (MSA) |
| Confidence calibration error | ≤ 0.10 |
| Time to first extracted key-term display | ≤ 30s P95, contracts ≤ 20 pages |
| Chat response latency | ≤ 15s P95 |
| Cost per contract analysis | ≤ $0.25 |
| 30-day user retention | ≥ 45% |
| AI correction rate | ≤ 12% of terms manually corrected |
| Chat hallucination rate | ≤ 5% (monthly expert review) |

These are product-level metrics, not per-PR gates — they're measured via the offline eval suite and production monitoring described in `docs/ContractIQ_PRD.md` §10, not asserted directly in unit/integration tests. The per-feature Acceptance Criteria above are the testable proxies for them at implementation time.
