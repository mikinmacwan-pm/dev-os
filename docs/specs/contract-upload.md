# Spec: Contract Upload & Text Extraction

Covers the upload screen: contract-type selection, PDF drop/pick, server-side text extraction with `[PAGE N]` markers, validation limits, the pre-processing standard-terms preview, and custom key-term registration. Ends when the user clicks "Process Contract," which hands off to `docs/specs/ai-key-term-extraction.md`.

## User Flow

1. User selects contract type (`NDA` | `MSA`) from a dropdown.
2. User drags/picks a PDF. Frontend validates client-side (`.pdf` mime type, ≤ 10 MB) before uploading.
3. Frontend calls `POST /api/contracts/upload`. While the request is in flight, the UI shows the standard-terms preview list for the selected type (see below) with a loading affordance on top ("Extracting text...").
4. On success, the UI shows the full preview (standard terms + a "+ Add Key Term" affordance) and enables custom-term entry.
5. User adds 0–5 custom terms; each call to `POST /api/contracts/[id]/custom-terms` appends to the preview with a "Custom" badge.
6. User clicks "Process Contract" → hands off to the AI extraction spec.

## Standard term lists (hardcoded, per contract type)

**NDA:** Parties, Effective Date, Confidentiality Obligations, Permitted Disclosures, Term & Duration, Governing Law, Jurisdiction, IP Ownership, Non-Solicitation, Breach & Remedy.

**MSA:** Parties, Service Scope, Payment Terms, Invoice Schedule, Late Payment Penalty, Liability Cap, Indemnification, IP Ownership, Termination Clause, Governing Law, Dispute Resolution, Notice Period.

These live as a constant map in `lib/claude/standard-terms.ts` — `STANDARD_TERMS: Record<"NDA" | "MSA", string[]>` — and are the single source of truth for both the pre-processing preview and the extraction prompt's target-term list (see the AI extraction spec).

## DB Schema

Relevant columns (full definitions in `docs/specs/supabase-schema.sql`):

- `contracts(id, user_id, contract_type, file_name, file_path, contract_text, status, created_at, updated_at)`
- `custom_key_terms(id, contract_id, term_name, created_at)` — capped at 5 rows per `contract_id` by a DB trigger (defense in depth) and by the API route (primary enforcement, returns a clean 400 instead of a raw DB error).

## DB Tasks

- `INSERT` into `contracts` with `status='pending'` once text extraction succeeds.
- Best-effort upload to Supabase Storage (path `{user_id}/{contract_id}/{filename}.pdf` within the `contracts` bucket — no redundant leading "contracts/" segment, see `docs/specs/supabase-schema.sql`); on success `UPDATE contracts SET file_path = ...`; on failure, leave `file_path` `null` and continue (non-blocking — the text-viewer fallback covers this case, see `docs/specs/results-viewer.md`).
- `INSERT` into `custom_key_terms` per term name submitted.

## API Routes

### `POST /api/contracts/upload`
- **Auth:** required.
- **Request:** `multipart/form-data` — `file` (PDF), `contract_type` (`"NDA" | "MSA"`).
- **Response 201:** `{ "contract_id": string, "standard_terms": string[] }`.
- **Server logic:**
  1. Validate `contract_type` is `NDA` or `MSA` (else `400 invalid_contract_type`).
  2. Validate file is `application/pdf` and ≤ 10 MB (else `413 file_too_large` / `400 invalid_file_type`).
  3. Extract text via `pdf-parse` using a custom `pagerender` callback that appends a `\n[PAGE ${pageNum}]\n` marker before each page's text, producing a single `contract_text` string with markers throughout.
  4. Validate page count ≤ 20 (count of `[PAGE N]` markers) — else `422 too_many_pages`.
  5. Validate extracted text has ≥ 100 words — else `422 scanned_pdf_unsupported` with message "Scanned PDFs are not supported yet."
  6. Validate token count ≤ 15,000 via `anthropic.messages.countTokens({ model: "claude-sonnet-5", messages: [{ role: "user", content: contractText }] })` (never approximate with a non-Claude tokenizer) — else `422 contract_too_long`.
  7. Insert the `contracts` row (`status='pending'`), attempt the Storage upload (non-blocking, see above), return `contract_id` + `STANDARD_TERMS[contract_type]`.

### `POST /api/contracts/[id]/custom-terms`
- **Auth:** required; contract must belong to the caller.
- **Request:** `{ "term_names": string[] }`, 1–5 items, each 1–100 chars.
- **Response 201:** `{ "custom_terms": [{ "id": string, "term_name": string }] }`.
- **Validation:** reject if the contract already has 5 custom terms, or if this request would push it over 5 (`400 too_many_custom_terms`).
- **Errors:** `404 contract_not_found` if the contract doesn't exist or isn't owned by the caller.

## State Management

`useUploadContract()` — a React Query mutation wrapping the upload call, exposing `isPending` for the "Extracting text..." state. `useAddCustomTerm()` — a mutation that optimistically appends the term to the local preview list before the server confirms, rolling back on error.

## Component Spec

- `<ContractTypeSelector>` — dropdown, required before upload is enabled.
- `<UploadDropzone>` — drag-and-drop + click-to-browse, client-side size/type validation with inline error text before any network call.
- `<StandardTermsPreview terms={STANDARD_TERMS[type]} customTerms={...} />` — renders standard terms plainly and custom terms with a "Custom" badge.
- `<CustomTermInput>` — text input + "+ Add Key Term" button, disabled once 5 custom terms exist, with a visible "3/5 custom terms" counter.
- `<ProcessContractButton>` — disabled until upload succeeds; triggers the AI-extraction flow (`docs/specs/ai-key-term-extraction.md`).

## Design

Dropzone and preview cards follow `docs/design.md` spacing/elevation tokens; the "Custom" badge uses the design system's accent token, distinct from the confidence-score colour tokens used later in the results view (do not reuse green/amber/red here — they mean something different).

## Edge Cases

- File exceeds 10 MB → rejected client-side before any upload attempt, with the exact limit stated in the error text.
- More than 20 pages → `422 too_many_pages`, message: "This contract has more than 20 pages — ContractIQ supports up to 20 pages at MVP."
- Scanned/image PDF (< 100 extracted words) → `422 scanned_pdf_unsupported`, message: "Scanned PDFs are not supported yet."
- Contract exceeds 15,000 tokens (but ≤ 20 pages, e.g. dense legalese) → `422 contract_too_long`, message: "This contract is too long for automatic review."
- Non-PDF file selected → rejected client-side immediately.
- 6th custom term attempted → `400 too_many_custom_terms`, button already disabled client-side as the primary defense.
- Supabase Storage upload fails (network/outage) → upload still succeeds from the user's perspective (`contract_id` returned, `contract_text` stored); only the later PDF-viewer experience is affected, not shown as an error at this step.

## Acceptance Criteria

- [ ] Uploading a valid ≤10 MB, ≤20-page PDF succeeds and returns a `contract_id` plus the correct standard-term list for the selected contract type (US-002, FR-02).
- [ ] Files >10 MB are rejected client-side before any network request.
- [ ] PDFs with >20 pages are rejected with `422 too_many_pages`.
- [ ] Scanned PDFs (<100 extracted words) are rejected with `422 scanned_pdf_unsupported` and the exact message "Scanned PDFs are not supported yet."
- [ ] Contracts exceeding 15,000 tokens are rejected with `422 contract_too_long`, verified via Claude's `count_tokens` endpoint, never a non-Claude approximation.
- [ ] Up to 5 custom terms can be added pre-processing, each appearing in the preview with a "Custom" badge (US-005, FR-05).
- [ ] A 6th custom term is rejected both client-side (disabled control) and server-side (`400 too_many_custom_terms`).
- [ ] `contract_text` is stored with `[PAGE N]` markers at upload time; no downstream step (process, chat) re-reads the PDF file (FR-03).
- [ ] A Storage upload failure does not block or fail the upload response — `contract_id` and `contract_text` are still returned and stored.
