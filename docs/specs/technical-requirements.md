# Technical Requirements

Cross-cutting, non-functional requirements that apply across every feature spec in `docs/specs/`. Sourced from `docs/ContractIQ_PRD.md` §5 (Constraints) and `docs/engineering/engineering-doc.md`, translated to the Claude-based architecture where the PRD's original OpenAI-specific numbers don't apply directly. These are requirements to build and test against, not a checklist for a separate stage — every relevant number here is already referenced from the feature specs' Acceptance Criteria.

## Performance

| Requirement | Target | Applies to |
|---|---|---|
| End-to-end extraction latency (upload → results displayed) | ≤ 30s P95, contracts ≤ 20 pages | `docs/specs/ai-key-term-extraction.md` |
| Time to first extracted key-term display | ≤ 30s P95, contracts ≤ 20 pages | `docs/specs/ai-key-term-extraction.md`, `docs/specs/results-viewer.md` |
| Chat response latency | ≤ 15s P95 | `docs/specs/contract-chat.md` |
| Each Claude API call | ≤ 20s P95 | `lib/claude/*` (extraction + chat) |
| Inline key-term edit save | ≤ 2s | `docs/specs/results-viewer.md` |
| Auth flow (sign up / sign in) | ≤ 10s | `docs/specs/auth.md` |
| Feedback/export file generation (if implemented) | ≤ 5s | `docs/specs/feedback.md` |

Client-side timeouts must be set with headroom above these budgets (e.g. chat's 20s client timeout against a 15s P95 target) so a slow-but-successful response isn't cut off, while a genuinely hung request still surfaces an error rather than spinning indefinitely.

## Upload & Document Constraints

- PDF uploads: **≤ 10 MB**, **≤ 20 pages**. Reject outside these limits with a specific, user-facing error (never a generic failure).
- Contract length: **≤ 15,000 tokens**, measured via Claude's `count_tokens` endpoint — never approximated with a non-Claude tokenizer (`docs/specs/contract-upload.md`).
- Only **text-layer PDFs** are supported at MVP. Scanned/image PDFs must fail gracefully with "Scanned PDFs are not supported yet." Trigger: extracted text < 100 words.
- Only **NDA and MSA** English-language (US/UK legal convention) contracts are in scope. No language/jurisdiction detection is required at MVP — this is a documented limitation, not a validation rule.
- Maximum **5 custom key terms** per contract, enforced at both the API layer (primary, returns a clean `400`) and the database layer (defense in depth, via a trigger — see `docs/specs/supabase-schema.sql`).

## Cost

- Cost per contract analysis: **≤ $0.25** (extraction target **≤ $0.20**), at Claude Sonnet 5 pricing ($3/$15 per MTok, or the $2/$10 introductory rate through 2026-08-31). A 20-page contract (~15K input + ~1.5K output tokens) runs **≈$0.067–0.10** per analysis — see `docs/engineering/engineering-doc.md` §8 for the full derivation.
- The extraction system prompt (few-shot examples, standard-term list) is cached via `cache_control: ephemeral` on every extraction call, and the chat system prompt (full contract text) is cached the same way per session, to keep repeated-call cost down.
- No hard cost-alerting mechanism is required in application code at MVP; monitor via the Anthropic Console/usage dashboard. Revisit if usage approaches the budget threshold.

## Scalability

- Must handle **100 concurrent contract analyses** without degradation during beta.
- Architecture must support horizontal scaling to **1,000 concurrent users** post-launch — Next.js API Routes on Vercel and Supabase both scale horizontally by default; no MVP code should assume in-memory state that isn't safe across multiple serverless instances (e.g. the rate limiter uses Vercel KV, not a local in-process map).

## Reliability

- **99.5% uptime** target.
- Claude API errors must be caught and surfaced with a human-readable message and a retry option — **no silent failures**. Every Claude-calling route (`process`, `chat`) follows the same pattern: retry with exponential backoff (extraction: schema-retry once + up to 3 attempts on network/5xx; chat: same backoff policy), then a typed error surfaced to the client, never a raw 500 with no explanation.
- A failed extraction leaves the contract in `status='error'`, retryable from the dashboard without re-upload (`contract_text` is already persisted).
- Supabase Storage is **non-blocking**: a Storage outage or upload failure degrades the PDF viewer to the text-viewer fallback; it never fails the upload or extraction pipeline, because the AI pipeline reads `contracts.contract_text` from the database, never the stored file.

## Security & Compliance

Full implementation detail (RLS policy verification, rate limiting, prompt-injection protection, audit logging, environment-variable handling) is Stage 7's deliverable (`/security-foundation`) — the requirements below are what that stage must satisfy, restated here so they're visible at the spec level:

- All data encrypted at rest (Supabase default: AES-256) and in transit (TLS 1.3).
- Row Level Security enforced on **every** table — see `docs/specs/supabase-schema.sql` for the full policy set. Every table's ownership check must be verified by an automated cross-user-access test (attempt to read/write another user's rows and assert denial) before launch.
- Supabase Storage signed URLs expire after **1 hour**.
- The `ANTHROPIC_API_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are server-only and must never reach the client bundle — verified by the `.env.local.example` `SERVER ONLY` annotations and never referenced from a `"use client"` file or a `NEXT_PUBLIC_*` variable.
- Data retention: uploaded PDFs retained 90 days post-last-access, then auto-deleted (a scheduled job — out of scope for the Stage 4 feature specs, tracked as a Stage 7/operational concern). Users can delete a contract and all associated data at any time (cascading deletes are already modeled via `on delete cascade` foreign keys in the schema).
- GDPR-readiness: no contract content is used to train any third-party model; the Anthropic API is called without training opt-in. User data deletion on request is satisfied by the cascading-delete schema design.

## Usability & Accessibility

- **WCAG 2.1 AA** compliance across every screen — keyboard navigability (especially the PDF viewer controls and chat input), colour-independent status indicators (confidence badges pair an icon + text label, not colour alone), sufficient contrast per `docs/design.md`'s token choices.
- No onboarding/training should be required — legal jargon is either avoided in the UI copy or accompanied by a plain-English tooltip.
- The "This is an AI-assisted review tool, not legal advice" disclaimer is present on every results page (`docs/specs/results-viewer.md`), not just at sign-up.

## AI Provider

Anthropic Claude API, model `claude-sonnet-5` — see `docs/engineering/engineering-doc.md` §8 for the full rationale, including why this diverges from the PRD's OpenAI GPT-4o baseline. Structured output uses `output_config.format` (json_schema), not "JSON mode." No `temperature`/`top_p`/`top_k` sampling parameters are set on extraction or chat calls — Sonnet 5 rejects non-default values for these; determinism and tone are controlled via prompting and `output_config.effort`, not sampling.
