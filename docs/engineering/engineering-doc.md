# ContractIQ — Engineering Document

**Status:** Draft — Stage 1 output, pending approval
**Source:** `docs/ContractIQ_PRD.md` (v1.0)
**AI Provider:** Anthropic Claude API (see note below — this diverges from the PRD, which specifies OpenAI GPT-4o)

> **Note on AI provider.** The PRD (§6–9) specifies OpenAI GPT-4o for extraction and chat. This repository's `README.md` fixes the AI provider for all dev-os builds as the **Anthropic Claude API**. This was confirmed with the product owner during planning. Every AI-specific detail below (model ID, context window, structured-output mechanism, pricing, prompt shape) is translated from the PRD's OpenAI-based spec to its Claude equivalent — the *product* requirements (extraction schema, confidence scoring, grounding strategy, guardrails) are unchanged from the PRD.

---

## 1. Executive Summary

**Project:** ContractIQ — an AI-assisted contract review tool for Non-Disclosure Agreements (NDA) and Master Service Agreements (MSA).

**Business goal:** Business professionals — founders, ops managers, procurement leads — routinely sign NDAs and MSAs without full understanding of the terms, at a cost of 90–120 minutes of manual review or $250–500/hr in ad-hoc legal fees. ContractIQ automatically extracts the key terms that matter for each contract type, attributes each term to the page and sentence it came from, scores its own confidence, and lets the user ask follow-up questions grounded strictly in the uploaded document — closing the gap between "no legal review" and "$1,500–3,000 lawyer-reviewed contract."

**Problem statement:** Existing tools are either built for enterprise legal teams with large budgets (DocuSign CLM, Ironclad, Kira) or are generic AI chat assistants with no structured extraction, page attribution, or confidence scoring. There is no affordable, purpose-built upload → extract → chat workflow for SMBs and freelancers reviewing NDA/MSA contracts.

**Target users:**
- **Primary — Time-Pressed Founder / Ops Lead:** SaaS/agency/professional-services/fintech/e-commerce, 5–250 employees, no in-house legal, signs 5–15 NDAs/MSAs per month.
- **Secondary — Freelancer / Consultant:** receives 1–4 client MSAs per month, cannot afford legal review, signs without full understanding due to power imbalance with larger clients.

**Success criteria (MVP → Public Launch, from PRD §3):**

| Metric | Target |
|---|---|
| Time from upload to completed review (North Star) | ≤ 15 minutes end-to-end |
| Key-term extraction accuracy | ≥ 88% F1 (NDA), ≥ 85% F1 (MSA) |
| Confidence calibration error | ≤ 0.10 |
| Time to first extracted key-term display | ≤ 30s P95 for ≤ 20-page contracts |
| Chat response latency | ≤ 15s P95 |
| Cost per contract analysis | ≤ $0.25 (target ≤ $0.20 extraction-only) |
| 30-day retention | ≥ 45% |
| AI correction rate | ≤ 12% of terms manually corrected |

---

## 2. Product Scope

**In scope (MVP):**
- Email/password auth (Supabase Auth)
- PDF upload (≤ 10 MB, ≤ 20 pages, ≤ 15,000 tokens), NDA or MSA contract type selection
- Server-side text extraction once at upload, with `[PAGE N]` markers, stored in the DB (never re-read from the file)
- AI-driven key-term extraction (standard term library per contract type) with page number, confidence score (0–100%), and verbatim source sentence per term
- Up to 5 user-defined custom key terms, extracted with the same structure as standard terms
- Confidence-based visual warnings (green ≥ 80%, amber 50–79%, red < 50%; never hidden)
- Two-panel results view: interactive PDF viewer (primary) with a paginated text-viewer fallback when Supabase Storage is unavailable
- Inline manual correction of extracted terms, with original AI value preserved for the feedback loop
- Contract chat (Q&A) grounded strictly in the uploaded document, with mandatory page citations and a "not found" fallback
- Persistent chat history per contract
- Dashboard with contract history (type, date, status), sortable
- Thumbs up/down feedback with optional comment (P2 — included in schema/spec now, UI can ship after core flow)
- "Not legal advice" disclaimer on every results page

**Out of scope (MVP):**
- Scanned/image PDFs (OCR) — graceful rejection only, deferred to v1.2
- Non-English contracts, or contracts outside US/UK legal conventions
- Export to CSV/PDF (P2/backlog — v1.1)
- Batch upload (v1.1)
- Contract comparison, multi-user/team workspaces, email notifications (v1.2)
- Any real-time collaborative editing or multi-user access to a single contract

**Future enhancements (post-MVP, from PRD roadmap):**
- v1.1: CSV/PDF export, batch upload (≤ 5 contracts), dashboard analytics
- v1.2: OCR for scanned PDFs, side-by-side contract comparison, email notifications, team workspaces

---

## 3. User Personas

| Persona | Role | Responsibilities in-app | Permissions |
|---|---|---|---|
| Time-Pressed Founder / Ops Lead | Founder, COO, Procurement/Legal Ops Manager | Uploads contracts, reviews extracted terms, corrects errors, asks chat questions, tracks review history on dashboard | Full CRUD on own contracts, key terms, chat sessions, feedback. No access to other users' data. |
| Freelancer / Consultant | Individual contributor | Same as above, typically reviewing MSAs sent by clients | Same as above |

There is a single application role for MVP — **`authenticated_user`** — enforced via Supabase Row-Level Security so every table scopes reads/writes to `auth.uid()`. No admin role, no team/workspace concept exists in the MVP; those are v1.2 backlog items and would introduce a second role (`workspace_admin`) at that time.

---

## 4. User Flows

Format: `User Action → Frontend Behavior → Backend Processing → Database Interaction → System Response`

### 4.1 Sign Up → Dashboard

1. User clicks "Get Started Free" on the landing page → Frontend opens the Supabase Auth sign-up form (email + password) → Backend: Supabase Auth creates the user record and session → Database: row inserted into `auth.users` (managed by Supabase) → System redirects to `/dashboard`, rendering the empty state: "No contracts reviewed yet — upload your first contract to begin."

### 4.2 Sign In → Dashboard (returning user)

1. User submits credentials → Frontend calls Supabase Auth sign-in → Backend validates credentials, issues a session → Database: Supabase Auth session table updated → System redirects to `/dashboard`, which fetches summary counts and the 5 most recent contracts via `GET /api/dashboard` → renders a summary card (total contracts, breakdown by type) and a "Review a Contract" CTA.

### 4.3 Core Flow — Contract Review

1. **Upload:** User selects contract type (NDA/MSA) and drops a PDF → Frontend validates file size/type client-side, shows the pre-processing preview of standard terms for the selected type → Backend `POST /api/contracts/upload` streams the file, runs `pdf-parse` to extract text with `[PAGE N]` markers, validates ≤ 20 pages / ≤ 10 MB / ≤ 15,000 tokens, rejects with a clear error if the extracted text is < 100 words (likely scanned) → Database: inserts a `contracts` row (`status='pending'`) with `contract_text` populated; best-effort upload to Supabase Storage (`file_path` set on success, left `null` on failure — non-blocking) → System returns the new `contract_id` and the standard term list for the UI preview.
2. **Custom terms (optional):** User clicks "+ Add Key Term" up to 5 times → Frontend appends each to the preview list with a "Custom" badge → Backend `POST /api/contracts/[id]/custom-terms` validates the 5-term cap and writes to `custom_key_terms`.
3. **Process:** User clicks "Process Contract" → Frontend shows a 3-step progress indicator → Backend `POST /api/contracts/[id]/process` calls the Claude API with the stored `contract_text` + contract type + custom terms, parses the structured JSON response, retries once on a parse failure → Database: writes one row per extracted term to `key_terms`, updates `contracts.status='complete'` (or `'error'` with a retry-safe state if the Claude call ultimately fails) → System renders the results page.
4. **Results page:** Frontend renders the two-panel view (PDF viewer or text-viewer fallback on the left, key-terms panel on the right: name, value, page, colour-coded confidence). Low-confidence terms (< 50%) show a ⚠️ and non-dismissible tooltip and auto-highlight the nearest matching page span. Each term has an expandable "Why?" showing the verbatim `source_sentence`.
5. **Manual correction:** User clicks a term's value to edit inline → Frontend optimistically updates, calls `PATCH /api/contracts/[id]/key-terms/[termId]` → Backend validates and writes `value`, `is_edited=true`, preserves `original_ai_value` if not already set → Database updates `key_terms` row → System shows an "Edited" badge, saved within 2 seconds.

### 4.4 Chat with Contract

1. User opens the "Chat" tab and types a question → Frontend posts to `POST /api/contracts/[id]/chat` and shows a loading state → Backend fetches `contracts.contract_text` and the full prior `chat_messages` history (ascending, ≤ 200 messages) for this contract's session, classifies the query (`contract` / `history` / `both`) to adjust the system prompt, calls the Claude API with a system prompt that forbids answering outside the provided document text and requires a `[Page X]` citation → Database inserts both the user message and the assistant response into `chat_messages` (linked to `chat_sessions` → `contracts`) → System renders the response left-aligned with a clickable page citation that scrolls the viewer to that page. Re-opening a contract's results page loads the persisted session via `GET /api/contracts/[id]/chat`.

---

## 5. Frontend Architecture

**Stack:** Next.js 14 (App Router) — fixed, per project convention. React 18, TypeScript, Tailwind CSS (per `README.md`; styling further governed by `docs/design.md` via the `/design-system` skill during Stage 4 implementation — Inter for UI text, JetBrains Mono for contract/source-sentence content, primary brand colour `#112E81`).

**State management:**
- **Server state** (contracts, key terms, chat messages, dashboard data): [TanStack React Query](https://tanstack.com/query) — handles caching, revalidation after mutations (term edits, chat sends), and the polling needed during the "processing" step.
- **Local/UI state:** component-local `useState`/`useReducer` (upload progress steps, modal open/close, PDF viewer zoom/page). No global client-side store (Redux/Zustand) is needed at MVP scope — chat and results state are scoped to a single contract page.
- **Auth state:** Supabase Auth's client SDK session, read via a thin `useUser()` hook wrapping `@supabase/ssr`.

**UX states (required for every data-driven screen):**
- **Loading:** skeleton panels on dashboard/results; 3-step progress indicator during contract processing (extracting text → analysing with AI → compiling results).
- **Empty:** dashboard empty state on first login.
- **Error:** upload rejection (size/page/token/scanned-PDF), Claude API timeout/failure ("Try again in a few minutes" CTA per PRD's reliability constraint), chat send failure.
- **Low-confidence warning:** non-dismissible tooltip + ⚠️ icon, never hides the term.
- **Responsive:** two-panel results collapse to a tabbed single-column layout below the `md` breakpoint.
- **Accessibility:** WCAG 2.1 AA — keyboard-navigable PDF viewer controls, `aria-live` region for chat responses, colour-independent confidence indicators (icon + text, not colour alone).

**Page / component hierarchy:**

```
app/
├── page.tsx                       # Landing page (static marketing content)
├── (auth)/
│   ├── login/page.tsx
│   └── signup/page.tsx
├── (app)/
│   ├── dashboard/page.tsx         # Summary + sortable contract list
│   └── contracts/
│       ├── new/page.tsx           # Upload + contract-type select + custom terms
│       └── [id]/page.tsx          # Results: PDF/text viewer + key-terms panel + chat
└── api/...                        # Route handlers, see §9
```

Key shared components: `<KeyTermsPanel>`, `<KeyTermRow>` (inline edit + confidence badge + "Why?" expandable), `<PdfViewer>` / `<TextViewerFallback>` (both accept a `targetPage` prop driven by term-click navigation, per PRD FR-06), `<ChatPanel>`, `<UploadDropzone>`, `<ContractTypeSelector>`, `<ConfidenceBadge>`, `<DisclaimerBanner>`.

---

## 6. Backend Architecture

**Stack:** Next.js API Routes (App Router route handlers) — this resolves the PRD's "Node.js / Supabase Edge Functions" ambiguity in favour of the project's fixed backend choice. The layer stays thin: orchestration only, no business logic beyond validation, Claude prompt assembly, and Supabase reads/writes.

**Core systems:**

- **Auth & session validation:** every route handler validates the Supabase session server-side via `@supabase/ssr`; unauthenticated requests return `401`. RLS is the second, DB-level enforcement layer (defense in depth).
- **PDF text extraction:** `pdf-parse`, run once at upload time inside `POST /api/contracts/upload`. Produces `contract_text` with `[PAGE N]` markers. No downstream route (`process`, `chat`) ever re-reads the PDF file — they read `contracts.contract_text` from the DB, per the PRD's explicit architecture note in FR-03.
- **Claude API orchestration:** a single `lib/claude/` module wraps the Anthropic SDK client, builds the extraction and chat prompts (see §8), parses/validates structured responses, and implements the retry policy.
- **Supabase Storage upload:** best-effort, non-blocking — a failure leaves `contracts.file_path = null` and only disables the PDF viewer (text-viewer fallback takes over); it never blocks or fails the extraction pipeline.
- **Validation:** Zod schemas per route (file size/type, contract type enum, custom-term count ≤ 5, term-edit payload shape).
- **Rate limiting:** a simple per-user token-bucket limiter (Supabase-backed or in-memory + Vercel KV) on `POST /api/contracts/[id]/process` and `POST /api/contracts/[id]/chat`, since both are the Claude-cost-bearing routes.
- **Error handling:** Claude API calls retry up to 3 times with exponential backoff; a final failure sets `contracts.status='error'` (so the user can retry from the dashboard without re-uploading) and returns a human-readable error — never a silent failure, per the PRD's reliability constraint.

**Service interaction diagram:**

```
┌────────────┐      ┌──────────────────────┐      ┌───────────────────┐
│  Frontend  │ ───▶ │  Next.js API Routes   │ ───▶ │  Supabase          │
│  (Next.js) │ ◀─── │  (thin orchestration) │ ◀─── │  Auth / Postgres /  │
└────────────┘      └──────────┬───────────┘      │  Storage           │
                                │                   └───────────────────┘
                                ▼
                     ┌───────────────────┐
                     │  Anthropic Claude  │
                     │  API (extraction,  │
                     │  chat)             │
                     └───────────────────┘
```

The Claude API key is read from `ANTHROPIC_API_KEY` server-side only and is never exposed to the client.

---

## 7. Database Design and Schema

Single Supabase (Postgres) project. Every table carries an owning `user_id` (directly or via `contract_id`), and RLS restricts all access to `auth.uid()`.

### `contracts`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid, PK | default `gen_random_uuid()` |
| `user_id` | uuid, FK → `auth.users(id)` | not null |
| `contract_type` | enum(`NDA`,`MSA`) | not null |
| `file_name` | text | original filename |
| `file_path` | text, nullable | Storage path `contracts/{user_id}/{id}/{filename}.pdf`; null if Storage upload failed |
| `contract_text` | text | full extracted text with `[PAGE N]` markers; single source of truth for AI pipeline |
| `status` | enum(`pending`,`processing`,`complete`,`error`) | drives dashboard + retry UX |
| `created_at` / `updated_at` | timestamptz | |

Indexes: `(user_id)`, `(user_id, status)`, `(created_at)` for dashboard sort.

### `key_terms`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid, PK | |
| `contract_id` | uuid, FK → `contracts(id)` | on delete cascade |
| `term_name` | text | e.g. "Governing Law" |
| `value` | text | current (possibly edited) value |
| `page_number` | int | 1-indexed |
| `confidence_score` | numeric(5,2) | 0–100 |
| `source_sentence` | text | verbatim sentence backing the extraction |
| `is_manual` | boolean | true for user-added custom terms |
| `is_edited` | boolean, default false | |
| `original_ai_value` | text, nullable | set once, on first edit, for the correction feedback loop |
| `created_at` / `updated_at` | timestamptz | |

Indexes: `(contract_id)`.

### `custom_key_terms`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid, PK | |
| `contract_id` | uuid, FK → `contracts(id)` | |
| `term_name` | text | user-supplied, injected into the extraction prompt |
| `created_at` | timestamptz | |

Application-layer constraint: max 5 rows per `contract_id` (enforced in the API route; a DB trigger may double-enforce it before GA).

### `chat_sessions`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid, PK | |
| `contract_id` | uuid, FK → `contracts(id)` | one active session per contract for MVP |
| `created_at` | timestamptz | |

Indexes: `(contract_id)`.

### `chat_messages`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid, PK | |
| `chat_session_id` | uuid, FK → `chat_sessions(id)` | |
| `role` | enum(`user`,`assistant`) | |
| `content` | text | |
| `page_citation` | int, nullable | parsed `[Page X]` from assistant responses |
| `created_at` | timestamptz | ascending order = conversation order |

Indexes: `(chat_session_id, created_at)`.

### `user_feedback`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid, PK | |
| `user_id` | uuid, FK → `auth.users(id)` | |
| `contract_id` | uuid, FK → `contracts(id)` | |
| `rating` | enum(`up`,`down`) | |
| `comment` | text, nullable | |
| `created_at` | timestamptz | |

### `term_corrections` (view)

`SELECT * FROM key_terms WHERE is_edited = true` — feeds the ≤12%-correction-rate monitoring described in PRD §8/§10 without a separate write path.

### Supabase Storage

- Bucket: `contracts` (created via `INSERT INTO storage.buckets`, not the dashboard — per PRD Assumption 13).
- Path convention: `contracts/{user_id}/{contract_id}/{filename}.pdf`.
- RLS on `storage.objects`: `INSERT` / `SELECT` / `DELETE` policies each require `auth.uid()::text = (storage.foldername(name))[1]`.
- Signed URLs for the PDF viewer expire after 1 hour (regenerated on each results-page load).

### RLS summary

Every table above has `user_id`-scoped (directly, or via `contract_id`/`chat_session_id` join) `SELECT`/`INSERT`/`UPDATE`/`DELETE` policies restricted to `auth.uid()`. This is the concrete deliverable of Stage 2 (`docs/specs/supabase-schema.sql`).

---

## 8. AI Architecture

**Provider:** Anthropic Claude API (per project-fixed stack; overrides the PRD's OpenAI GPT-4o spec).

**Model:** `claude-sonnet-5` — 1,000,000-token context window (comfortably covers the PRD's ≤15,000-token contract cap plus prompt + history overhead) and up to 128,000 max output tokens.

**Structured output (extraction):** Claude Sonnet 5 does not have an OpenAI-style "JSON mode." Structured, schema-validated extraction is achieved with `output_config.format` (a `json_schema` matching the term shape below), or equivalently `strict: true` tool use if a tool-call shape is preferred by implementation. This directly replaces the PRD's `response_format: { type: "json_object" }`.

```json
// Extraction output schema (per term)
{
  "term_name": "string",
  "value": "string",
  "page_number": "integer",
  "confidence_score": "number (0-100)",
  "source_sentence": "string"
}
```

**Prompt strategy:**

| Task | Technique | Notes |
|---|---|---|
| Key-term extraction | Few-shot (3 labelled NDA examples + 3 MSA examples) in the Claude `system` prompt, structured output via `output_config.format` | Same few-shot approach as the PRD, adapted from OpenAI's system/user role split to Anthropic's `system` + `messages` request shape |
| Custom term extraction | Zero-shot — custom term names appended to the same extraction prompt/schema | Unchanged from PRD |
| Confidence scoring | Self-reported by the model within the same extraction call (no second inference) | Unchanged from PRD |
| Contract chat | Full `contract_text` + full ascending `chat_messages` history (≤ 200 messages) passed every turn; system prompt: "Answer only from the document text provided. If the answer is not in the document, say so." Mandatory `[Page X]` citation. | Same grounding strategy as PRD §7/§8; query classification (`contract`/`history`/`both`) still adjusts the system prompt without an extra API call |
| Error recovery | On a JSON-schema validation failure, one automatic retry with an explicit "return only valid JSON matching the schema" instruction | Unchanged from PRD |

**Sampling / determinism:** Claude Sonnet 5 rejects non-default `temperature`/`top_p`/`top_k` — the PRD's "temperature 0.1 for extraction, 0.4 for chat" has no direct equivalent. Determinism for extraction instead comes from the fixed JSON schema + few-shot examples; a moderate `output_config.effort` (`medium`) is used for extraction to bound latency/cost, and chat runs at the model's default effort with prompting (not sampling) used to keep responses natural and concise.

**Token limits:** ~2,000 output tokens for extraction (bounded — a 10–12-term NDA/MSA extraction fits comfortably), ~1,000 output tokens for chat.

**Cost model (re-derived for Claude Sonnet 5 pricing — $3.00/$15.00 per MTok, or $2.00/$10.00 intro pricing through 2026-08-31):** a 20-page contract is ≈15,000 input tokens for extraction (contract text + few-shot examples) and ≈1,500 output tokens → **≈$0.067–0.10 per analysis** at standard pricing, well under the PRD's $0.20 extraction-only / $0.25 total ceiling — with headroom to spare even before caching. **Prompt caching:** the few-shot extraction system prompt (static across all NDA or all MSA requests) is marked `cache_control: ephemeral`, cutting the repeated-example cost on every extraction call after the first.

**Rate limiting & cost controls:** per-user rate limiting on the `process` and `chat` routes (see §6); monthly cost monitored against budget with alerting at 80% of threshold, mirroring the PRD's cost-governance plan.

**Fallback strategy:** the PRD's stated fallback ("evaluate Claude or Gemini if OpenAI cost doubles") is inverted since Claude is already the primary provider — the equivalent MVP posture is: monitor cost/quality, and evaluate a different Claude tier (e.g. Haiku for a cheaper/faster path, or Opus if accuracy is insufficient) before considering a different provider.

**Hallucination guardrails:** unchanged from the PRD (§9) — confidence scoring + colour coding, non-dismissible low-confidence warnings, mandatory `source_sentence` per term, document-only chat system prompt, mandatory page citation, "I cannot find this in the document" as a valid and expected chat response, "not legal advice" disclaimer on every results page.

---

## 9. API Specification

All routes require a valid Supabase session (server-side cookie/JWT check); unauthenticated requests return `401 { "error": { "code": "unauthorized", "message": "..." } }`. All error responses share the shape `{ "error": { "code": string, "message": string } }`.

### `POST /api/contracts/upload`
- **Purpose:** Upload a PDF, extract text, create the `contracts` row.
- **Auth:** required.
- **Request:** `multipart/form-data` — `file` (PDF, ≤10MB), `contract_type` (`NDA`|`MSA`).
- **Response 201:** `{ "contract_id": uuid, "standard_terms": string[] }`.
- **Validation:** file type `application/pdf`, size ≤ 10MB, page count ≤ 20, extracted text ≥ 100 words (else `422 scanned_pdf_unsupported`), token count ≤ 15,000 (else `422 contract_too_long`).
- **Errors:** `400 invalid_contract_type`, `413 file_too_large`, `422 scanned_pdf_unsupported`, `422 contract_too_long`.

### `POST /api/contracts/[id]/custom-terms`
- **Purpose:** Register up to 5 custom key terms before processing.
- **Auth:** required, contract must belong to caller.
- **Request:** `{ "term_names": string[] }` (1–5 items).
- **Response 201:** `{ "custom_terms": [{ "id": uuid, "term_name": string }] }`.
- **Validation:** total custom terms for the contract ≤ 5.
- **Errors:** `400 too_many_custom_terms`, `404 contract_not_found`.

### `POST /api/contracts/[id]/process`
- **Purpose:** Trigger Claude extraction and persist `key_terms`.
- **Auth:** required, ownership check.
- **Request:** `{}` (no body — reads `contracts.contract_text`, `contract_type`, and `custom_key_terms` server-side).
- **Response 200:** `{ "status": "complete", "key_terms": [...] }`.
- **Validation:** contract must be in `status='pending'`.
- **Errors:** `409 already_processing`, `502 ai_extraction_failed` (after 3 retries — sets `contracts.status='error'`).

### `GET /api/contracts/[id]`
- **Purpose:** Fetch a contract's full results view data.
- **Auth:** required, ownership check.
- **Response 200:** `{ "contract": {...}, "key_terms": [...], "viewer": { "mode": "pdf"|"text", "signed_url"?: string, "pages"?: string[] } }`.
- **Errors:** `404 contract_not_found`.

### `PATCH /api/contracts/[id]/key-terms/[termId]`
- **Purpose:** Inline-edit an extracted term's value.
- **Auth:** required, ownership check.
- **Request:** `{ "value": string }`.
- **Response 200:** `{ "key_term": {...} }`.
- **Behavior:** on first edit, copies the pre-edit value into `original_ai_value`; sets `is_edited=true`.
- **Errors:** `404 term_not_found`.

### `POST /api/contracts/[id]/chat`
- **Purpose:** Send a chat message, get a grounded Claude response.
- **Auth:** required, ownership check.
- **Request:** `{ "message": string }`.
- **Response 200:** `{ "message": { "role": "assistant", "content": string, "page_citation": int|null } }`.
- **Errors:** `429 rate_limited`, `502 ai_chat_failed`.

### `GET /api/contracts/[id]/chat`
- **Purpose:** Load the persisted chat session for a contract.
- **Auth:** required, ownership check.
- **Response 200:** `{ "messages": [{ "role": "user"|"assistant", "content": string, "page_citation": int|null, "created_at": string }] }`.

### `GET /api/dashboard`
- **Purpose:** Dashboard summary + sortable contract list.
- **Auth:** required.
- **Query params:** `sort` (`date`|`name`|`type`), `order` (`asc`|`desc`).
- **Response 200:** `{ "total_contracts": int, "by_type": { "NDA": int, "MSA": int }, "contracts": [{ "id", "file_name", "contract_type", "status", "created_at" }] }`.

### `POST /api/contracts/[id]/feedback` (P2)
- **Purpose:** Submit thumbs up/down + optional comment.
- **Auth:** required, ownership check.
- **Request:** `{ "rating": "up"|"down", "comment"?: string }`.
- **Response 201:** `{ "feedback_id": uuid }`.

---

## 10. Feature Breakdown

### Phase 1 — MVP (maps to PRD v0.1–v0.4)
| Feature | Acceptance criteria (from PRD FR table) | Dependencies |
|---|---|---|
| Auth (sign up/in/out) | Completes within 10s; clear error on invalid credentials (FR-01) | Supabase project provisioned |
| PDF upload + extraction | Accepts ≤10MB; extraction ≤30s P95 for ≤20 pages (FR-02, FR-03) | Auth |
| Key-term extraction & display | Panel shows Term/Value/Page/Confidence (FR-04) | Upload, Claude API access |
| Confidence scoring | 0–100%, <50% shows warning (FR-04, FR-11) | Extraction |
| Custom key terms | ≥5 supported pre-processing, same output structure (FR-05) | Upload |
| Page attribution + navigation | Click page number scrolls viewer (FR-03, FR-07) | Extraction, PDF/text viewer |
| PDF viewer + text fallback | Viewer renders all pages; fallback works when Storage unavailable (FR-06) | Storage bucket + RLS |
| Contract chat | Responds ≤15s, grounded, cites page (FR-07, FR-08) | Extraction complete |
| Persistent chat history | Reload restores session (FR-09, US-012) | Chat |
| Dashboard + history | Shows totals, breakdown, sortable list (FR-10) | Auth, contracts data |
| Inline key-term editing | Saves ≤2s, "Edited" badge, original preserved (FR-09/US-009) | Extraction |

### Phase 2 — Launch hardening (maps to PRD v1.0)
Feedback submission (FR-12), end-to-end performance optimisation (≤30s P95), security audit (RLS verification, signed-URL expiry, API key handling — feeds Stage 7 `/security-foundation`), WCAG 2.1 AA review, rate limiting on Claude calls, onboarding tooltips.

### Phase 3 — Post-launch (maps to PRD v1.1–v1.2, backlog)
CSV/PDF export (US-011), batch upload (≤5 contracts), dashboard analytics charts, scanned-PDF OCR support, contract comparison view, email notifications, multi-user workspaces.

---

## 11. Folder Structure

```
contractiq/
├── app/
│   ├── page.tsx                          # Landing page
│   ├── (auth)/
│   │   ├── login/page.tsx
│   │   └── signup/page.tsx
│   ├── (app)/
│   │   ├── layout.tsx                    # Authenticated shell (nav, disclaimer footer)
│   │   ├── dashboard/page.tsx
│   │   └── contracts/
│   │       ├── new/page.tsx
│   │       └── [id]/page.tsx
│   └── api/
│       ├── contracts/
│       │   ├── upload/route.ts
│       │   └── [id]/
│       │       ├── route.ts              # GET
│       │       ├── process/route.ts
│       │       ├── custom-terms/route.ts
│       │       ├── key-terms/[termId]/route.ts
│       │       ├── chat/route.ts
│       │       └── feedback/route.ts
│       └── dashboard/route.ts
├── components/
│   ├── contracts/                        # KeyTermsPanel, KeyTermRow, PdfViewer, TextViewerFallback
│   ├── chat/                             # ChatPanel, ChatMessage
│   └── ui/                               # Shared design-system primitives (buttons, badges, tooltips)
├── lib/
│   ├── supabase/                         # server + client Supabase factories, RLS-aware queries
│   ├── claude/                           # Anthropic SDK client, prompt builders, schema validation
│   ├── pdf/                              # pdf-parse wrapper, [PAGE N] marker logic, token counting
│   └── validation/                       # Zod schemas per API route
├── types/                                # Shared TS types (Contract, KeyTerm, ChatMessage, ...)
├── docs/
│   ├── engineering/                      # this file + implementation-specs.md (Stage 1)
│   ├── specs/                            # Stage 2 output
│   └── security/                         # Stage 7 output
└── supabase/                             # migrations / rls-policies.sql (Stage 2/7 output)
```

---

## 12. Naming Conventions

| Category | Convention | Example |
|---|---|---|
| Files & folders | kebab-case | `key-terms-panel.tsx`, `contracts/new/` |
| React components | PascalCase | `KeyTermsPanel`, `PdfViewer` |
| Hooks | camelCase, `use` prefix | `useContract`, `useChatSession` |
| Functions/variables | camelCase | `extractKeyTerms`, `signedUrl` |
| DB tables & columns | snake_case | `key_terms`, `contract_id`, `confidence_score` |
| API routes | `/api/<resource>/<action>` | `/api/contracts/[id]/process` |
| Env vars | SCREAMING_SNAKE_CASE | `ANTHROPIC_API_KEY`, `SUPABASE_SERVICE_ROLE_KEY` |
| Config files | kebab-case, tool-standard names | `next.config.mjs`, `tailwind.config.ts` |
| Zod schemas | camelCase, `Schema` suffix | `uploadContractSchema` |

---

## 13. Testing Strategy

**Unit (Vitest):**
- Extraction JSON-schema parsing and validation (`lib/claude/`)
- Confidence-threshold → colour/warning logic
- `[PAGE N]` marker parsing and token-counting utilities (`lib/pdf/`)
- Prompt-builder functions (extraction and chat system prompts, given contract type / custom terms / history)

**Integration:**
- API routes exercised against a disposable/test Supabase project: upload → extraction → key-terms round trip; chat persistence; inline edit persisting `original_ai_value` correctly
- **RLS cross-user access tests** (explicitly called out as an internal risk in PRD §3): attempt to read/write another user's `contracts`/`key_terms`/`chat_messages`/`user_feedback` rows and assert denial — run in CI per the PRD's pre-launch security review requirement
- Storage upload failure path: confirm `file_path` stays `null` and the text-viewer fallback still serves content

**E2E (Playwright):**
- Golden path: sign up → upload NDA → process → view key terms → edit a term → ask a chat question → see cited response
- Auth flow: sign up, sign in, sign out, invalid-credential error
- Low-confidence term displays warning and is not hidden
- Upload rejection paths: oversized file, scanned PDF, too-long contract
- **Automated hallucination regression test** (PRD §9): feed the chat a question about a topic absent from the document, assert the response is "I cannot find this in the document" (or equivalent), not a fabricated answer

**Coverage targets:** ≥80% line coverage on `lib/claude/`, `lib/pdf/`, and API route handlers; E2E covers every P0/P1 user story from the PRD's functional-requirements table.

---

## 14. Specs to Implementation Mapping

| Spec area | Implementation files | Flow |
|---|---|---|
| Auth | `app/(auth)/*`, `lib/supabase/client.ts`, `lib/supabase/server.ts` | Supabase Auth SDK → session cookie → RLS on every table |
| Upload & text extraction | `app/api/contracts/upload/route.ts`, `lib/pdf/*`, `lib/validation/upload.ts` | Client upload → route validates → `pdf-parse` → `contracts` row |
| Key-term extraction | `app/api/contracts/[id]/process/route.ts`, `lib/claude/extract.ts` | `contracts.contract_text` → Claude `output_config.format` call → `key_terms` rows |
| Custom terms | `app/api/contracts/[id]/custom-terms/route.ts` | UI "+ Add Key Term" → `custom_key_terms` → injected into extraction prompt |
| Results display | `components/contracts/*`, `app/(app)/contracts/[id]/page.tsx` | `GET /api/contracts/[id]` → `<PdfViewer>`/`<TextViewerFallback>` + `<KeyTermsPanel>` |
| Inline editing | `app/api/contracts/[id]/key-terms/[termId]/route.ts` | `<KeyTermRow>` edit → `PATCH` → `key_terms` update |
| Chat | `app/api/contracts/[id]/chat/route.ts`, `lib/claude/chat.ts`, `components/chat/*` | `<ChatPanel>` → `POST`/`GET` chat routes → `chat_sessions`/`chat_messages` |
| Dashboard | `app/api/dashboard/route.ts`, `app/(app)/dashboard/page.tsx` | Aggregate query over `contracts` → summary card + sortable list |
| Feedback | `app/api/contracts/[id]/feedback/route.ts` | Thumbs up/down UI → `user_feedback` |
| Security (Stage 7) | `docs/security/security-plan.md`, `supabase/rls-policies.sql`, `src/lib/security/*` | RLS policies, rate limiting, prompt-injection guards, audit logging |

---

*This document is the authoritative reference for ContractIQ's architecture. No implementation begins until it is approved. Stage 2 (`/implementation-specs`) will translate this into granular, runnable specs plus `docs/specs/supabase-schema.sql` and `.env.example`.*
