# dev-os

**An AI-driven SDLC framework — designed once, then used with Claude Code to take a real product (ContractIQ) from a raw idea to a deployed, working application, stage by stage, with a working demo and no skipped steps hidden.**

🔗 **Try the product this built:** https://contractiq-pi.vercel.app · **[Code →](https://github.com/mikinmacwan-pm/contractiq)**

---

## What this is

Most "I used AI to build an app" portfolio pieces show you the output. This repo is the *process* — a repeatable, stage-gated workflow, implemented as a set of Claude Code [skills](#skills), where each stage produces a concrete artifact that has to exist and be reviewed before the next stage is allowed to start. `CLAUDE.md` in this repo is the actual governing instruction set — not documentation *about* the process, but the thing that enforces it turn by turn.

The point isn't "AI wrote the code." It's that a disciplined pipeline — requirements → architecture → granular specs → scaffold → feature-by-feature implementation, each gated on the previous stage's output — produces something more reviewable, more debuggable, and more honest about what's actually done versus deferred than an unstructured "build me an app" prompt does. Everything below is the real, unedited trail: the PRD, the architecture decisions (including the ones I had to override the PRD on), the specs, and the bugs the process actually caught.

## The pipeline

| Stage | Skill | Input → Output | Status |
|---|---|---|---|
| **0 — Product Requirements** | *(user-authored)* | Product idea → [`docs/ContractIQ_PRD.md`](docs/ContractIQ_PRD.md) (651 lines: problem, personas, metrics, user stories, technical requirements, grounding/hallucination strategy, eval plan) | ✅ Done |
| **1 — Engineering Plan** | `/engineering-planner` | PRD → [`docs/engineering/engineering-doc.md`](docs/engineering/engineering-doc.md) (architecture, DB design, API spec, folder structure) + [`implementation-specs.md`](docs/engineering/implementation-specs.md) | ✅ Done |
| **2 — Implementation Specs** | `/implementation-specs` | Engineering docs → [`docs/specs/*.md`](docs/specs/) — one runnable spec per feature, plus [`supabase-schema.sql`](docs/specs/supabase-schema.sql) and `.env.example` | ✅ Done |
| **3 — Frontend Setup** | `/frontend-setup` | Specs → scaffolded Next.js 14 (App Router) project, design tokens wired in | ✅ Done |
| **4 — Feature Implementation** | *(manual, one feature at a time)* | Specs → working code, one feature per pass, each verified against the live Supabase + Anthropic backend before moving on | ✅ Done — all 7 features |
| **5 — Testing** | *(not yet run)* | Automated unit/integration/E2E suite | ⏸️ Deliberately deferred — see below |
| **6 — Deploy** | *(manual)* | Live production deployment on Vercel, seeded demo account | ✅ Done |
| **7 — Security Hardening** | `/security-foundation` | Formal audit → `docs/security/security-plan.md`, rate-limit/prompt-injection/RLS hardening pass | ⏸️ Deliberately deferred — see below |

Every stage above stopped and waited for explicit approval before continuing — that's not a description, it's a hard rule enforced in `CLAUDE.md` ("Never move to the next stage without explicit user approval").

## What's deliberately deferred, and why that's stated here instead of hidden

`CLAUDE.md`'s own stage order puts **Testing (5) before Deploy (6)**. This deployment skipped ahead of it, on purpose, for portfolio timing — a live demo is worth more to a recruiter reading this than an unshipped, fully-tested app. That's a real trade-off, and pretending the process was followed perfectly linearly would defeat the point of documenting it honestly. What's actually missing:

- **Stage 5 — Testing.** No automated test suite yet. Every feature *was* manually verified end-to-end against the live Supabase + Anthropic backend during Stage 4 (not just "it compiles" — actual signup flows, actual PDF extraction, actual grounded chat responses checked against expected behavior), but that's not a substitute for a regression suite.
- **Stage 7 — Security Hardening.** RLS policies are in place on every table (see [`supabase-schema.sql`](docs/specs/supabase-schema.sql)) and every API route re-derives the session user server-side rather than trusting client input, but the formal audit pass (prompt-injection testing, rate-limit tuning, a documented `security-plan.md`) hasn't run yet.

## Notable moments where the process caught something real

The value of a gated pipeline shows up in what it catches, not just in the artifacts it produces:

- **A load-bearing bug found by re-reading my own approved spec.** The original `supabase-schema.sql` (Stage 2 output) documented the Storage file-path convention as `contracts/{user_id}/{contract_id}/...`, but the RLS policy checked `(storage.foldername(name))[1]` — the *first* path segment. The literal `contracts/` prefix would have shifted every ownership check off by one and silently failed every upload/download. Caught during Stage 4 implementation, before any user ever hit it, by tracing the RLS policy against the path convention it was supposed to enforce — not by trial and error in production.
- **A race condition closed with a constraint, not a comment.** The chat feature lazily creates one session per contract on first message. Two concurrent first-messages could have created two sessions under load. Fixed with a `unique (contract_id)` database constraint plus a `23505`-conflict retry in the route handler — enforced at the data layer, not just assumed away in application logic.
- **A production-only build failure, caught before it shipped.** `pdf.js`'s worker is an ES module; Next.js's production Terser pass failed trying to minify it — invisible in `next dev`, fatal in `next build`. Running the actual production build as part of verification (not just the dev server) surfaced it before deploy, not after.
- **A type-safety regression from an upstream dependency, root-caused rather than worked around.** A newer `@supabase/supabase-js` release changed its generic-type contract in a way that silently collapsed every database query's return type to `never` — no build error, just untyped data at runtime. Diagnosed with an isolated type-probe file rather than guessing, and fixed at the type-definition layer instead of sprinkling `as any` around the codebase.

Full technical write-up of the app these decisions live in: **[ContractIQ README →](https://github.com/mikinmacwan-pm/contractiq)**

## Current project: ContractIQ

An AI-assisted contract review tool for NDAs and MSAs — upload a contract, get its key terms extracted with page-level citations and confidence scores, then ask it questions in plain English, grounded strictly in the document. Built with Next.js 14, Supabase (Postgres + Auth + Storage, full RLS), and the Anthropic Claude API.

- **Live demo + demo login:** see the [ContractIQ README](https://github.com/mikinmacwan-pm/contractiq)
- **PRD:** [`docs/ContractIQ_PRD.md`](docs/ContractIQ_PRD.md)
- **Architecture:** [`docs/engineering/engineering-doc.md`](docs/engineering/engineering-doc.md)
- **Feature specs:** [`docs/specs/`](docs/specs/) — one file per feature (auth, upload, extraction, results viewer, chat, dashboard, feedback), each with user flow, DB schema, API contract, edge cases, and acceptance criteria
- **Database schema:** [`docs/specs/supabase-schema.sql`](docs/specs/supabase-schema.sql)

## Folder structure

```
dev-os/
├── CLAUDE.md                          # The actual stage-gate rules — read this first
├── docs/
│   ├── ContractIQ_PRD.md              # Stage 0 output
│   ├── design.md                      # Brand design system (colors, typography, spacing)
│   ├── engineering/                   # Stage 1 output
│   │   ├── engineering-doc.md
│   │   └── implementation-specs.md
│   └── specs/                         # Stage 2 output
│       ├── README.md                  # Index of every spec + consolidated API reference
│       ├── *.md                       # One spec per feature
│       └── supabase-schema.sql
└── skills/                            # The Claude Code skills that drive each stage
    ├── engineering-planner/
    ├── implementation-specs/
    ├── security-foundation/
    ├── frontend-setup/
    └── design-system/
```

> `contractiq/` (the Stage 3–6 output) now lives in [its own repo](https://github.com/mikinmacwan-pm/contractiq) — a recruiter clicking into the product shouldn't have to wade through process docs first, and a recruiter reading the process shouldn't have to wade through `node_modules`-adjacent noise.

## Skills

Skills live in `skills/<name>/SKILL.md` and are invoked as slash commands in Claude Code.

| Skill | Command | What it does |
|---|---|---|
| Engineering Planner | `/engineering-planner` | PRD → `docs/engineering/engineering-doc.md` + `implementation-specs.md`. Asks clarifying questions (auth strategy, DB, LLM provider, user roles) before generating anything. |
| Implementation Specs | `/implementation-specs` | Engineering docs → granular, runnable specs, one file per concern. Always produces `supabase-schema.sql` and `.env.example`. |
| Security Foundation | `/security-foundation` | Reviews all engineering/spec docs, identifies every security surface, implements controls (RLS, rate limiting, prompt injection, file validation) before feature code is written. |
| Frontend Setup | `/frontend-setup` | Scaffolds a complete Next.js 14 (App Router) project matching the specs' folder structure and conventions. |
| Design System | `/design-system` | Enforces the brand design system (`docs/design.md`) on every piece of UI code — colors, spacing, typography, component styles. |

## Key rules (from `CLAUDE.md`)

- **Never skip a stage.** Each stage depends on the previous one's approved output.
- **Never proceed without explicit approval.** The process stops and waits after every stage — including this deployment, which is why the deferred stages above are named instead of quietly skipped.
- **Never assume missing decisions.** Ambiguity gets a clarifying question, not a guess.
- **Never write code before specs exist.** Implementation only starts after Stage 2 is approved.
