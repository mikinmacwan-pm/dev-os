# ContractIQ — Implementation Specs

**Status:** Draft — Stage 1 output, pending approval
**Companion to:** `docs/engineering/engineering-doc.md` (architecture, DB design, API spec, AI architecture)

One detailed spec block per feature: user flow, DB schema, DB tasks, API routes, state management, component spec, design, edge cases. This is the feature-level breakdown referenced by the engineering doc's Feature Breakdown (§10) and Specs-to-Implementation Mapping (§14). Stage 2 (`/implementation-specs`) will expand each block below into a standalone, granular, runnable spec file under `docs/specs/`, plus the paste-and-run `docs/specs/supabase-schema.sql` and `.env.example`.

---

## Feature: Authentication

**User flow:** Landing page → "Get Started Free" → sign-up form (email, password) → Supabase Auth creates the account and sends a confirmation email → user clicks the emailed link → session established → redirect to `/dashboard` (empty state). Returning users sign in via `/login`; sign-out clears the session and returns to `/`. Every route under `(app)/` is gated by middleware that checks for a valid session and redirects unauthenticated requests to `/login?redirect=<path>`.

**DB schema:** No custom tables — identity lives entirely in Supabase-managed `auth.users`. Every other table's `user_id` column is a `references auth.users(id) on delete cascade` foreign key, so deleting a user cascades through all of their contracts, key terms, chat data, and feedback.

**DB tasks:** None beyond what Supabase Auth manages internally.

**API routes:** No custom API routes for the core auth actions (sign up/in/out use the Supabase client SDK directly). One route: `GET /auth/callback` — exchanges the emailed confirmation code for a session, then redirects to `/dashboard`.

**State management:** `useUser()` hook backed by React Query (`["user"]`), populated from `supabase.auth.getUser()` on mount and kept in sync via `supabase.auth.onAuthStateChange()`.

**Component spec:** `<AuthForm mode="signup"|"login">` (email/password fields, client-side validation, loading + error states), `<CheckYourEmailNotice>` (post-signup), `<UserMenu>` (avatar/email + sign-out, in the authenticated shell).

**Design:** Primary CTA uses the brand primary colour from `docs/design.md`; Inter for form labels/inputs; errors use the design system's semantic "error" token, never a hardcoded colour.

**Edge cases:** Invalid credentials show a generic "Invalid email or password" (never reveal which field is wrong); duplicate sign-up shows "An account with this email already exists"; auth calls must complete within 10 seconds per FR-01 — a timeout state with retry is shown if exceeded; session expiry mid-use redirects to `/login` and returns the user to their original page after re-auth; sign-in with an unconfirmed email shows a "please confirm your email" message with a resend action.

---

## Feature: Contract Upload & Text Extraction

**User flow:** User selects contract type (NDA/MSA) → drags or picks a PDF (client-side validated for type/size before upload) → `POST /api/contracts/upload` extracts text server-side and returns the standard-term preview for that type → user optionally adds up to 5 custom key terms, each appearing in the preview with a "Custom" badge → user clicks "Process Contract" to hand off into extraction.

**DB schema:** `contracts(id, user_id, contract_type, file_name, file_path, contract_text, status, created_at, updated_at)`; `custom_key_terms(id, contract_id, term_name, created_at)`, capped at 5 rows per contract.

**DB tasks:** Insert the `contracts` row (`status='pending'`) once text extraction succeeds; best-effort, non-blocking Storage upload (`file_path` set on success, left `null` on failure — this never fails the upload itself); insert one `custom_key_terms` row per submitted term name.

**API routes:**
- `POST /api/contracts/upload` — `multipart/form-data` (`file`, `contract_type`) → `201 { contract_id, standard_terms }`. Validates PDF type/size (≤10MB), page count (≤20, counted from `[PAGE N]` markers inserted during extraction), word count (≥100, else `422 scanned_pdf_unsupported`), and token count (≤15,000, checked via Claude's `count_tokens`, else `422 contract_too_long`).
- `POST /api/contracts/[id]/custom-terms` — `{ term_names: string[] }` (1–5) → `201 { custom_terms }`. Rejects with `400 too_many_custom_terms` if the contract would exceed 5.

**State management:** `useUploadContract()` mutation (exposes `isPending` for the "Extracting text..." state); `useAddCustomTerm()` mutation with an optimistic local append.

**Component spec:** `<ContractTypeSelector>`, `<UploadDropzone>` (drag/drop + browse, client-side validation before any network call), `<StandardTermsPreview>`, `<CustomTermInput>` (disabled at 5/5 with a visible counter), `<ProcessContractButton>` (disabled until upload succeeds).

**Design:** Dropzone/preview cards follow `docs/design.md` spacing/elevation tokens; the "Custom" badge uses a distinct accent token from the confidence-score colours used later in the results view.

**Edge cases:** oversized/non-PDF files rejected client-side before upload; >20 pages → `422 too_many_pages`; scanned/image PDF (<100 extracted words) → "Scanned PDFs are not supported yet"; >15,000 tokens → "This contract is too long for automatic review"; 6th custom term attempt blocked both client-side (button disabled) and server-side (`400`); Storage upload failure is invisible to the user at this step — only the later viewer experience is affected.

---

## Feature: AI Key-Term Extraction

**User flow:** User clicks "Process Contract" → a 3-step progress indicator plays (extracting text — already done; analysing with AI; compiling results) → on success the user is navigated to the results page.

**DB schema:** Reads `contracts.contract_text`/`contract_type` and all `custom_key_terms` for the contract; writes `key_terms(id, contract_id, term_name, value, page_number, confidence_score, source_sentence, is_manual, is_edited, original_ai_value)` and updates `contracts.status`.

**DB tasks:** Set `status='processing'` before calling Claude; on success, bulk-insert one `key_terms` row per extracted term (standard + custom) and set `status='complete'`; on failure after retries, set `status='error'` with no partial rows written.

**API routes:** `POST /api/contracts/[id]/process` — no body → `200 { status: "complete", key_terms }`. Preconditions: contract must be `status='pending'` (a contract in `status='error'` is silently reset to `'pending'` internally first, which is what powers dashboard "Retry" without re-upload). Returns `409` if already processing/complete, `502 ai_extraction_failed` after exhausted retries.

**AI call (Claude Sonnet 5):** `output_config.format` json_schema over `{ term_name, value, page_number, confidence_score, source_sentence }[]`; system prompt carries 3 few-shot examples per contract type plus the full standard-term target list (cached via `cache_control: ephemeral` since it's identical across calls of the same type); user message is the `[PAGE N]`-marked contract text plus any custom term names. One automatic retry on schema-invalid output; up to 3 attempts total with exponential backoff on network/5xx errors. A term genuinely absent from the document is still returned, with `value: "Not found in document"` and `confidence_score: 0` — never omitted.

**State management:** `useProcessContract(contractId)` mutation; the 3-step indicator is presentational (step 1 shown as already complete, step 2 animates for the request duration, step 3 flashes on response before navigation).

**Component spec:** `<ProcessingProgress>` (3-step indicator), reuses `<KeyTermsPanel>` from the results viewer once complete.

**Design:** N/A beyond the shared progress-indicator styling from `docs/design.md`.

**Edge cases:** fewer terms returned than expected → retried once, then partial results accepted rather than failing the whole contract; hallucinated `page_number` outside the valid range is clamped, not rejected; `confidence_score` outside 0–100 is clamped before insert (the DB check constraint would otherwise reject the whole batch); zero custom terms means the custom-term clause is omitted from the prompt entirely; a double-click on "Process Contract" is rejected with `409` because the first request already flipped `status` before the second arrives.

---

## Feature: Results Viewer (PDF/Text Viewer + Key Terms Panel)

**User flow:** User lands on `/contracts/[id]` → left panel shows the interactive PDF viewer (or the paginated text-viewer fallback if Storage is unavailable) → right panel shows the key-terms list. Clicking a term's page number scrolls the viewer to that page. Clicking a term's value opens inline edit; saving persists within 2 seconds and shows an "Edited" badge. Low-confidence terms show a non-dismissible warning and an expandable "Why?" with the verbatim source sentence.

**DB schema:** Reads `contracts(file_path, contract_text, contract_type)` and all `key_terms` for the contract; updates `key_terms.value`/`is_edited`/`original_ai_value` on inline edit.

**DB tasks:** `SELECT` the contract + ordered `key_terms`; on edit, `UPDATE ... SET value=$1, is_edited=true, original_ai_value = COALESCE(original_ai_value, <pre-edit value>)` — so `original_ai_value` is only ever set once, on the first edit.

**API routes:**
- `GET /api/contracts/[id]` — returns `{ contract, key_terms, viewer }`, where `viewer.mode` is `"pdf"` (with a freshly generated 1-hour signed URL) or `"text"` (with `contract_text` pre-split into per-page strings on the `[PAGE N]` markers) when `file_path` is `null`.
- `PATCH /api/contracts/[id]/key-terms/[termId]` — `{ value: string }` → `200 { key_term }`, must complete within 2 seconds (FR-09), no synchronous AI calls on this path.

**State management:** `useContract(id)` (React Query); `useUpdateKeyTerm(id)` mutation with optimistic update + rollback; `targetPage` state lifted to the route component, shared between the viewer and the terms panel.

**Component spec:** `<PdfViewer signedUrl, targetPage>` (react-pdf, scroll/zoom, smooth-scroll to `targetPage`), `<TextViewerFallback pages, targetPage>` (same `targetPage` prop contract as the PDF viewer), `<KeyTermsPanel>` → `<KeyTermRow>` (inline edit, clickable page number, `<ConfidenceBadge>`, "Edited" pill, "Why?" disclosure), `<DisclaimerBanner>` (persistent, every results page).

**Design:** JetBrains Mono for the "Why?" source-sentence block and raw contract text in the fallback viewer; confidence colours (green ≥80 / amber 50–79 / red <50) come from the design system's semantic tokens, not raw hex values.

**Edge cases:** `file_path = null` degrades silently to the text viewer with no error shown; an expired signed URL (>1hr session) triggers one automatic re-fetch of `GET /api/contracts/[id]` before showing a manual reload button; repeated edits never overwrite the true original AI value; a `confidence_score = 0` / "Not found in document" term is still rendered, never hidden (FR-11).

---

## Feature: Contract Chat

**User flow:** User opens the "Chat" tab → existing persisted messages load → user sends a question → the assistant's grounded, cited response appears → clicking the citation scrolls the document viewer to that page. Reopening the contract later restores the full session.

**DB schema:** `chat_sessions(id, contract_id, created_at)` (one per contract, created lazily on first message); `chat_messages(id, chat_session_id, role, content, page_citation, created_at)`.

**DB tasks:** Fetch up to 200 prior messages ascending before every call; insert both the user message and the assistant response together, only after a successful Claude call (a failed turn never leaves an orphaned, unanswered user message in history).

**API routes:**
- `POST /api/contracts/[id]/chat` — `{ message }` → `200 { message: { role: "assistant", content, page_citation } }`. Rate-limited per user; ≤15s P95 latency budget; `502 ai_chat_failed` on exhausted retries.
- `GET /api/contracts/[id]/chat` — returns the full persisted message list (empty array if no session yet).

**AI call (Claude Sonnet 5):** System prompt embeds the full `contract_text` (cached via `cache_control: ephemeral`) and forbids answering outside it, requiring a trailing `[Page X]` citation on every response; a lightweight keyword heuristic (no extra API call) classifies whether a question also references prior conversation and adjusts the prompt accordingly; the full ascending message history is replayed every turn (per PRD Assumption 14).

**State management:** `useChatMessages(contractId)` (React Query, seeded from `GET .../chat`); `useSendChatMessage(contractId)` mutation, optimistic append of the user's message, rollback on failure.

**Component spec:** `<ChatPanel>` (message list + input), `<ChatMessage role, content, pageCitation>` (right-aligned user / left-aligned assistant, clickable citation pill), `<ChatEmptyState>` (example prompts).

**Design:** Consistent with the results viewer's typography/colour tokens; citation pills use the same interactive-link styling as the key-term page-number links for visual continuity.

**Edge cases:** a required automated regression test asserts that a question about a topic absent from a fixture document returns exactly "I cannot find this in the document."; a missing citation in the model's output is still displayed (just without a clickable pill) and logged for prompt review; history beyond 200 messages is truncated for the model context but remains fully visible in the UI thread; the send button is disabled while a response is in flight to prevent re-entrant sends.

---

## Feature: Dashboard

**User flow:** User signs in → `/dashboard` loads a summary card (total contracts, NDA/MSA breakdown) and a sortable contract list, or an empty state on first login → clicking a row opens that contract's results page; a "Review a Contract" CTA is present in both states.

**DB schema:** Reads `contracts(id, contract_type, file_name, status, created_at)`, scoped to `auth.uid()` via RLS.

**DB tasks:** Read-only — a scoped `SELECT` for the list plus a `GROUP BY contract_type` aggregate for the summary counts.

**API routes:** `GET /api/dashboard?sort=&order=` → `200 { total_contracts, by_type, contracts }`.

**State management:** `useDashboard(sort, order)` (React Query, key includes sort/order); invalidated whenever a contract is uploaded or finishes processing.

**Component spec:** `<DashboardSummaryCard>`, `<ContractsTable>` (sortable by name/type/date/status; `error`-status rows expose an inline "Retry" action that re-invokes the process route without navigating away), `<DashboardEmptyState>`, `<ReviewContractCTA>`.

**Design:** Status badges reuse the badge component family from `<ConfidenceBadge>` but with distinct semantic colours (status ≠ confidence).

**Edge cases:** zero contracts shows only the empty state; a `processing` contract shows a "Processing..." badge with no auto-polling (state updates on next visit/refetch); very long file names are truncated with a hover title.

---

## Feature: Feedback (P2)

**User flow:** On the results page, user picks 👍/👎 and optionally adds a comment, then submits; resubmitting with a different rating overwrites the prior one rather than creating a duplicate.

**DB schema:** `user_feedback(id, user_id, contract_id, rating, comment, created_at)` with a `unique (user_id, contract_id)` constraint enabling upsert semantics.

**DB tasks:** `INSERT ... ON CONFLICT (user_id, contract_id) DO UPDATE SET rating = excluded.rating, comment = excluded.comment`.

**API routes:** `POST /api/contracts/[id]/feedback` — `{ rating, comment? }` → `201 { feedback_id }` (upsert); `GET /api/contracts/[id]/feedback` (optional, pre-populates the widget) → `200 { feedback | null }`.

**State management:** `useFeedback(contractId)`; `useSubmitFeedback(contractId)` mutation with optimistic selected-state.

**Component spec:** `<FeedbackWidget rating, comment, onSubmit>` — two mutually-exclusive icon toggles + a collapsible comment field revealed after a rating is chosen.

**Design:** Selected state uses the brand primary colour — deliberately not the green/red confidence vocabulary, since this is sentiment, not a status or confidence signal.

**Edge cases:** a comment without a rating is rejected client-side; a contract belonging to another user returns `404`, never `403`, to avoid confirming existence to a non-owner.

---

*This document, together with `docs/engineering/engineering-doc.md`, is the complete Stage 1 output. No implementation begins until both are approved. Stage 2 (`/implementation-specs`) expands each block above into a standalone spec file plus the runnable Supabase SQL and `.env.example`.*
