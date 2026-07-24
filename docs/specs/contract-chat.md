# Spec: Contract Chat (Claude, grounded Q&A)

Covers the chat tab on the results page: sending a question, calling Claude with the full contract text + full conversation history, enforcing document-only grounding with mandatory page citations, and persisting the conversation.

## User Flow

User opens the "Chat" tab on `/contracts/[id]` → on first open, `GET /api/contracts/[id]/chat` loads any existing persisted session (empty on first visit) → user types a question and sends → `POST /api/contracts/[id]/chat` returns the grounded answer → both messages render in the thread (user right-aligned, assistant left-aligned) with the assistant message's citation rendered as a clickable `[Page X]` pill that sets the shared `targetPage` state (see `docs/specs/results-viewer.md`) to scroll the document viewer.

## DB Schema

Relevant columns (full definitions in `docs/specs/supabase-schema.sql`): `chat_sessions(id, contract_id, created_at)`, `chat_messages(id, chat_session_id, role, content, page_citation, created_at)`.

## DB Tasks

- Lazily create a `chat_sessions` row for the contract on the *first* message if none exists yet (one session per contract for MVP — no "new conversation" concept).
- `SELECT * FROM chat_messages WHERE chat_session_id = $1 ORDER BY created_at ASC LIMIT 200` before every chat call, to build history.
- `INSERT` both the user message and the assistant response into `chat_messages` in the same request (two rows) after a successful Claude call — never insert the user message if the Claude call fails, so a failed turn doesn't pollute history with an unanswered question.

## Claude Integration (`lib/claude/chat.ts`)

**Model:** `claude-sonnet-5`. **Max output tokens:** 1000.

**System prompt template** (`buildChatSystemPrompt({ contractText, queryType })`, cached via `cache_control: { type: "ephemeral" }` since `contractText` is stable for the life of the session):

```
You are ContractIQ's contract assistant. Answer only from the document text
provided below. If the answer is not in the document, respond exactly:
"I cannot find this in the document." Every response must end with a
citation in the form [Page X] referencing the page where the answer was
found. Do not use general legal knowledge or information about this
contract type beyond what appears in the text below.

<document>
{contractText}
</document>
```

When `queryType` is `"history"` or `"both"`, append: "The user may also ask about earlier parts of this conversation — you have the full conversation history above; answer from it directly when relevant."

**Query classification** (`classifyQuery(message): "contract" | "history" | "both"`) — a fast keyword heuristic, **not** an extra API call (per PRD Assumption 14):

```ts
const HISTORY_MARKERS = /\b(earlier|before|you said|you mentioned|previously|what did (i|you) )/i;

function classifyQuery(message: string): "contract" | "history" | "both" {
  return HISTORY_MARKERS.test(message) ? "both" : "contract";
}
```

**Call shape:**

```ts
const history = await getChatHistory(sessionId); // ascending, <=200 rows
const response = await anthropic.messages.create({
  model: "claude-sonnet-5",
  max_tokens: 1000,
  system: [{ type: "text", text: systemPrompt, cache_control: { type: "ephemeral" } }],
  messages: [
    ...history.map((m) => ({ role: m.role, content: m.content })),
    { role: "user", content: message },
  ],
});
```

**Response parsing:** extract the trailing citation with `/\[Page (\d+)\]/i`; store the captured page number in `page_citation` (nullable — if the model fails to include one, still persist and display the text, and log the miss for prompt-quality monitoring since it should never happen per the system prompt).

## API Routes

### `POST /api/contracts/[id]/chat`
- **Auth:** required; ownership check.
- **Request:** `{ "message": string }` (1–2000 chars).
- **Response 200:** `{ "message": { "role": "assistant", "content": string, "page_citation": number | null, "created_at": string } }`.
- **Rate limiting:** per-user token bucket (Vercel KV) to bound Claude cost on this route.
- **Latency budget:** ≤ 15s P95 (PRD constraint) — client shows a 20s client-side timeout with a "Try again" retry.
- **Errors:** `429 rate_limited`, `502 ai_chat_failed` (Claude API error after retry).

### `GET /api/contracts/[id]/chat`
- **Auth:** required; ownership check.
- **Response 200:** `{ "messages": [{ "role": "user" | "assistant", "content": string, "page_citation": number | null, "created_at": string }] }` — empty array if no session exists yet.

## State Management

`useChatMessages(contractId)` — React Query, key `["chat", contractId]`, seeded from `GET .../chat` on mount. `useSendChatMessage(contractId)` — mutation that optimistically appends the user's message to the local cache immediately, then appends the assistant response (or rolls back the optimistic user message and shows an inline error on failure).

## Component Spec

- `<ChatPanel>` — message list (auto-scrolls to bottom on new message) + `<ChatInput>` (textarea + send button, disabled while a response is in flight).
- `<ChatMessage role, content, pageCitation, onCitationClick>` — right-aligned bubble for `role="user"`, left-aligned for `role="assistant"`; assistant bubbles render the citation as a clickable pill.
- `<ChatEmptyState>` — shown before the first message, with 2–3 example prompts ("What happens if I breach this NDA?", "Is there an auto-renewal clause?").

## Edge Cases

- **Hallucination regression test (required, per PRD §9):** an automated test sends a question about a topic verifiably absent from a fixture contract and asserts the response is exactly "I cannot find this in the document." — run in CI alongside the RLS tests.
- Question unrelated to the contract or to prior chat (e.g. "What's the weather?") → the document-only system prompt should produce the "I cannot find this" fallback; this is a valid, expected response, not an error.
- Claude response omits `[Page X]` → still persisted and displayed (citation pill omitted), logged for prompt review — never blocks the user from seeing the answer.
- Chat history exceeds 200 messages → only the most recent 200 (ascending) are sent as context; older messages remain in the DB and are still shown in the UI thread, just not replayed to the model.
- User sends a message while a previous one is still in flight → send button is disabled client-side; the mutation is not re-entrant.

## Acceptance Criteria

- [ ] A chat response is grounded strictly in the uploaded document and includes a `[Page X]` citation (US-007, FR-08).
- [ ] Chat responses arrive within 15 seconds P95.
- [ ] A question about a topic absent from the document returns exactly "I cannot find this in the document." — verified by an automated regression test (PRD §9).
- [ ] All chat messages (user + assistant) are persisted to Supabase with role and timestamp (FR-09).
- [ ] Reopening a contract's results page restores the full prior chat session (US-012).
- [ ] The full ascending conversation history (up to 200 messages) is replayed to the model on every turn.
- [ ] Clicking a response's citation scrolls the document viewer to the cited page.
