# Spec: Results Viewer (PDF/Text Viewer + Key Terms Panel)

Covers the two-panel results page (`/contracts/[id]`): the interactive PDF viewer with a paginated text-viewer fallback, the key-terms panel with confidence-coloured rows, inline editing, page-click navigation, and the "Why?" source-sentence expandable.

## User Flow

User lands on `/contracts/[id]` (from the process step, the dashboard, or a direct link) → `GET /api/contracts/[id]` loads contract + key terms + viewer data → left panel renders `<PdfViewer>` (if a signed URL is available) or `<TextViewerFallback>` (if `file_path` is `null`) → right panel renders `<KeyTermsPanel>`. Clicking a term's page number scrolls/jumps the left panel to that page. Clicking a term's value opens inline edit; saving calls `PATCH .../key-terms/[termId]`. Low-confidence terms (< 50%) show a warning icon; clicking it expands the "Why?" section and jumps the viewer to the term's page.

## DB Schema

Relevant columns (full definitions in `docs/specs/supabase-schema.sql`): `contracts(file_path, contract_text, contract_type)`, `key_terms(*)` (all columns are displayed or drive UI state).

## DB Tasks

- `SELECT` the contract row + all `key_terms` rows ordered by a stable display order (standard terms in `STANDARD_TERMS` order, then custom terms).
- On inline edit: `UPDATE key_terms SET value = $1, is_edited = true, original_ai_value = COALESCE(original_ai_value, <pre-edit value>) WHERE id = $2`.

## API Routes

### `GET /api/contracts/[id]`
- **Auth:** required; ownership check.
- **Response 200:**
  ```json
  {
    "contract": { "id": "...", "contract_type": "NDA", "file_name": "...", "status": "complete" },
    "key_terms": [ { "id": "...", "term_name": "...", "value": "...", "page_number": 2, "confidence_score": 92.5, "source_sentence": "...", "is_manual": false, "is_edited": false } ],
    "viewer": { "mode": "pdf", "signed_url": "https://...", "expires_at": "..." }
  }
  ```
  or, when `file_path` is `null`:
  ```json
  { "viewer": { "mode": "text", "pages": ["page 1 text...", "page 2 text..."] } }
  ```
  `pages` is derived server-side by splitting `contract_text` on the `[PAGE N]` markers.
- **Signed URL:** generated on every call via `supabase.storage.from("contracts").createSignedUrl(path, 3600)` (1-hour expiry, per PRD reliability constraint) — never cached beyond the response.
- **Errors:** `404 contract_not_found`.

### `PATCH /api/contracts/[id]/key-terms/[termId]`
- **Auth:** required; ownership check (via the term's `contract_id`).
- **Request:** `{ "value": string }` (1–2000 chars).
- **Response 200:** `{ "key_term": { ...updated row } }`.
- **SLA:** must complete within 2 seconds (FR-09) — no synchronous AI calls on this path.
- **Errors:** `404 term_not_found`.

## State Management

`useContract(id)` — React Query, key `["contract", id]`. `useUpdateKeyTerm(id)` — mutation with optimistic update (immediately reflect the new value + "Edited" badge in the cache, roll back on error) to hit the 2-second perceived-save target. `targetPage` is `useState` lifted to the `[id]/page.tsx` route component and passed to both the viewer and the panel so a term-click can drive the viewer regardless of which viewer mode is active.

## Component Spec

- `<PdfViewer signedUrl, targetPage, onPageChange>` — built on `react-pdf` (pdf.js). Renders all pages with lazy loading, supports scroll + zoom controls, scrolls smoothly to `targetPage` on change with a brief highlight flash on the target page.
- `<TextViewerFallback pages, targetPage>` — renders each entry of `pages` as a labelled `<section id="page-N">`, scrolls to the matching section on `targetPage` change. Must expose the same `targetPage` prop contract as `<PdfViewer>` so the parent component doesn't need to branch behavior.
- `<KeyTermsPanel terms, onTermClick, onEdit>` — maps each term to `<KeyTermRow>`.
- `<KeyTermRow term, onPageClick, onEdit>` — displays `term_name`, editable `value` (click-to-edit inline, save/cancel), `page_number` as a clickable link, `<ConfidenceBadge score={confidence_score}>`, an "Edited" pill when `is_edited`, and an expandable "Why?" disclosure showing `source_sentence` verbatim in a monospace block.
- `<ConfidenceBadge score>` — green (≥ 80), amber (50–79), red (< 50) per the design system's semantic tokens; red additionally renders a ⚠️ icon and a non-dismissible tooltip: "Low confidence — we recommend verifying this in the document directly."
- `<DisclaimerBanner>` — persistent, on every results page: "This is an AI-assisted review tool, not legal advice. Always verify critical terms with a qualified lawyer." Plus a "Powered by Anthropic Claude" attribution in the footer.

## Design

JetBrains Mono for the `source_sentence` "Why?" block and any raw contract text shown in the text-viewer fallback (per `docs/design.md`); Inter for all other UI text. Confidence colours must come from the design system's semantic tokens, not raw hex values, so they stay consistent with any future palette changes.

## Edge Cases

- `file_path` is `null` (Storage upload failed at upload time, or Storage is down) → `viewer.mode = "text"` is returned transparently; no error banner is shown to the user, per the architecture's "failure only hides the PDF viewer" principle.
- Signed URL expires while the user is still on the page (> 1 hour) → `<PdfViewer>` catches the load failure and calls `GET /api/contracts/[id]` again to obtain a fresh URL, retrying the load once automatically before showing a manual "Reload viewer" button.
- User edits a term, then edits it again → `original_ai_value` is set only on the *first* edit (`COALESCE` in the update) so repeated edits never overwrite the true original AI output.
- Term has `confidence_score = 0` / `value = "Not found in document"` → still rendered as a normal (red-badged) row, never hidden, per PRD FR-11.
- Very long `value` (e.g. a full clause pasted as a term value) → truncate in the collapsed row with a "show more" affordance; the edit textarea itself has no truncation.

## Acceptance Criteria

- [ ] Every extracted term displays its page number, and clicking it scrolls the viewer (PDF or text fallback) to that page (US-003, FR-07).
- [ ] Every term displays a confidence score 0–100%, colour-coded green (≥80) / amber (50–79) / red (<50) (US-004).
- [ ] Terms with confidence <50% show a non-dismissible ⚠️ warning and are never hidden from the panel (FR-11).
- [ ] The PDF viewer renders all pages, supports scroll and zoom, and highlighted term references are clickable (US-006).
- [ ] When `file_path` is `null`, the text-viewer fallback renders transparently with no error shown to the user, and supports the same page-navigation contract (`targetPage`) as the PDF viewer (FR-06).
- [ ] Inline-editing a term's value persists within 2 seconds, shows an "Edited" badge, and preserves the original AI value in `original_ai_value` (US-009, FR-09).
- [ ] Editing an already-edited term does not overwrite the true original AI value a second time.
- [ ] The "Why?" disclosure shows the exact verbatim `source_sentence` for the term.
- [ ] The "not legal advice" disclaimer is present on every results page.
