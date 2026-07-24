# Spec: AI Key-Term Extraction (Claude)

Covers the "Process Contract" step: calling Claude Sonnet 5 to extract structured key terms (standard + custom) from `contracts.contract_text`, validating the response, and persisting `key_terms`. See `docs/engineering/engineering-doc.md` §8 for the provider-level rationale (Claude, not the PRD's OpenAI GPT-4o).

## User Flow

User clicks "Process Contract" on the upload/preview screen → frontend shows a 3-step progress indicator (extracting text — already done at upload; analysing with AI; compiling results) → `POST /api/contracts/[id]/process` runs the extraction → on success, frontend navigates to `/contracts/[id]` (the results view, `docs/specs/results-viewer.md`).

## DB Schema

Relevant columns (full definitions in `docs/specs/supabase-schema.sql`):

- `contracts(contract_text, contract_type, status)` — read `contract_text`/`contract_type`, write `status`.
- `custom_key_terms(term_name)` — read all rows for the contract.
- `key_terms(id, contract_id, term_name, value, page_number, confidence_score, source_sentence, is_manual, is_edited, original_ai_value)` — bulk insert one row per extracted term.

## DB Tasks

1. `SELECT contract_text, contract_type FROM contracts WHERE id = $1` + `SELECT term_name FROM custom_key_terms WHERE contract_id = $1`.
2. `UPDATE contracts SET status = 'processing'` before calling Claude.
3. On success: bulk `INSERT INTO key_terms (...)` — standard terms with `is_manual = false`, custom terms also `is_manual = false` for the AI-populated row (the `is_manual` flag distinguishes *user-added term names* which is already captured by their presence in `custom_key_terms`; `key_terms.is_manual` is set `true` only if the value itself was hand-entered by the user via inline edit before any AI value existed — for MVP this never happens since extraction always runs first, so `is_manual` is `false` for every row created by this endpoint). Then `UPDATE contracts SET status = 'complete'`.
4. On failure after retries: `UPDATE contracts SET status = 'error'` — no partial `key_terms` rows are written (all-or-nothing insert).

## Claude Integration (`lib/claude/extract.ts`)

**Model:** `claude-sonnet-5`. **Structured output:** `output_config.format` with a `json_schema` matching:

```json
{
  "type": "object",
  "properties": {
    "terms": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "term_name": { "type": "string" },
          "value": { "type": "string" },
          "page_number": { "type": "integer" },
          "confidence_score": { "type": "number" },
          "source_sentence": { "type": "string" }
        },
        "required": ["term_name", "value", "page_number", "confidence_score", "source_sentence"],
        "additionalProperties": false
      }
    }
  },
  "required": ["terms"],
  "additionalProperties": false
}
```

**System prompt** (`buildExtractionSystemPrompt(contractType)`, cached via `cache_control: { type: "ephemeral" }` since it's identical across every extraction call for a given contract type): includes 3 labelled few-shot examples for the selected type (NDA or MSA), the full standard-term target list from `STANDARD_TERMS[contractType]` (see `docs/specs/contract-upload.md`), and this instruction block:

> Extract the value for every listed term from the contract text below. For each term, return the exact value, the 1-indexed page number where it appears (using the `[PAGE N]` markers in the text), a confidence score from 0–100 reflecting how certain you are, and the verbatim sentence the value was drawn from. If a term is not present anywhere in the document, return `"value": "Not found in document"` and `"confidence_score": 0` — do not omit the term.

**User message:** the contract text (with `[PAGE N]` markers intact) followed by the custom term names to also extract, e.g.:

```
<document>
{contract_text}
</document>

Also extract these custom terms using the same rules: {custom_term_names.join(", ")}
```

**Call shape:**

```ts
const response = await anthropic.messages.create({
  model: "claude-sonnet-5",
  max_tokens: 2000,
  output_config: { format: { type: "json_schema", schema: EXTRACTION_SCHEMA }, effort: "medium" },
  system: [{ type: "text", text: systemPrompt, cache_control: { type: "ephemeral" } }],
  messages: [{ role: "user", content: userMessage }],
});
```

**Retry policy:**
- Schema-invalid or unparseable JSON → **one** automatic retry, appending: "Your previous response did not match the required schema. Return only valid JSON matching the schema." to the message list.
- Network error / 5xx / rate limit → up to **3** attempts total with exponential backoff (1s, 2s, 4s), per the PRD's reliability constraint.
- Exhausted retries → throw a typed `ExtractionFailedError`; the route handler catches it, sets `contracts.status='error'`, and returns `502 ai_extraction_failed`.

## API Route

### `POST /api/contracts/[id]/process`
- **Auth:** required; contract must belong to the caller.
- **Request:** `{}` (no body).
- **Response 200:** `{ "status": "complete", "key_terms": KeyTerm[] }`.
- **Preconditions:** contract must have `status = 'pending'` (else `409 already_processing` if `'processing'`, or `409 already_complete` if `'complete'` — processing is not re-triggerable from this endpoint; a separate "Retry" action on an `'error'` contract re-invokes this same route since a `'pending'`-equivalent reset happens first).
- **Retry-from-error:** if `status = 'error'`, this route resets it to `'pending'` internally and proceeds — this is what powers the dashboard's "Retry" action without re-upload.

## State Management

`useProcessContract(contractId)` — a React Query mutation. The frontend's 3-step progress indicator is purely presentational (a timed/staged UI, since the actual work happens in one request-response cycle): step 1 ("Extracting text") is shown as already-complete immediately (extraction happened at upload), step 2 ("Analysing with AI") animates for the duration of the in-flight request, step 3 ("Compiling results") shows briefly on response before navigating to the results page.

## Edge Cases

- Model returns fewer terms than the standard list (e.g. omits one) → treat as a schema violation and retry once; if it persists after retry, insert whatever valid terms were returned rather than failing the whole contract (partial results are better than none, and low term count will be visually obvious to the user).
- Model hallucinates a `page_number` outside `1..totalPages` → clamp to the nearest valid page during response validation (log a warning; do not fail the request).
- `confidence_score` outside `0–100` → clamp before insert (the DB `check` constraint would otherwise reject the whole batch insert).
- Contract has 0 custom terms → the "Also extract these custom terms" clause is omitted from the user message entirely (not sent as an empty list).
- User double-clicks "Process Contract" → the second request hits `409 already_processing` because the first request already flipped `status` to `'processing'` before calling Claude.

## Acceptance Criteria

- [ ] Clicking "Process Contract" on a valid `pending` contract returns extracted terms and navigates to the results page.
- [ ] The key-terms panel shows values for ≥80% of the standard terms for the contract's type (US-002).
- [ ] Every returned term includes a `page_number`, `confidence_score` (0–100), and a verbatim `source_sentence` (FR-04).
- [ ] Terms absent from the document are still returned, with `value: "Not found in document"` and `confidence_score: 0` — never silently omitted (FR-11).
- [ ] Extraction completes within 30 seconds P95 for contracts ≤20 pages, measured from upload to results displayed.
- [ ] A schema-invalid Claude response triggers exactly one automatic retry before either succeeding or surfacing `502 ai_extraction_failed`.
- [ ] A failed extraction sets `contracts.status='error'` with zero partial `key_terms` rows written (all-or-nothing).
- [ ] Re-invoking `process` on an `'error'` contract succeeds without requiring re-upload.
- [ ] Concurrent double-submission of "Process Contract" is rejected with `409 already_processing` on the second request.
