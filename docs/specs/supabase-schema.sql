-- ============================================================================
-- ContractIQ — Supabase schema
-- Paste this entire file into the Supabase SQL Editor and run once on a
-- fresh project. Safe to re-run (uses IF NOT EXISTS / OR REPLACE / ON CONFLICT
-- guards throughout).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Extensions
-- ----------------------------------------------------------------------------
create extension if not exists pgcrypto;

-- ----------------------------------------------------------------------------
-- Enums
-- ----------------------------------------------------------------------------
do $$ begin
  create type contract_type as enum ('NDA', 'MSA');
exception when duplicate_object then null; end $$;

do $$ begin
  create type contract_status as enum ('pending', 'processing', 'complete', 'error');
exception when duplicate_object then null; end $$;

do $$ begin
  create type chat_role as enum ('user', 'assistant');
exception when duplicate_object then null; end $$;

do $$ begin
  create type feedback_rating as enum ('up', 'down');
exception when duplicate_object then null; end $$;

-- ----------------------------------------------------------------------------
-- Tables (dependency order)
-- ----------------------------------------------------------------------------

create table if not exists public.contracts (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  contract_type  contract_type not null,
  file_name      text not null,
  file_path      text,
  contract_text  text not null,
  status         contract_status not null default 'pending',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index if not exists idx_contracts_user_id on public.contracts(user_id);
create index if not exists idx_contracts_user_status on public.contracts(user_id, status);
create index if not exists idx_contracts_created_at on public.contracts(created_at desc);

create table if not exists public.key_terms (
  id                 uuid primary key default gen_random_uuid(),
  contract_id        uuid not null references public.contracts(id) on delete cascade,
  term_name          text not null,
  value              text not null,
  page_number        int not null check (page_number >= 1),
  confidence_score   numeric(5,2) not null check (confidence_score >= 0 and confidence_score <= 100),
  source_sentence    text not null,
  is_manual          boolean not null default false,
  is_edited          boolean not null default false,
  original_ai_value  text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create index if not exists idx_key_terms_contract_id on public.key_terms(contract_id);

create table if not exists public.custom_key_terms (
  id           uuid primary key default gen_random_uuid(),
  contract_id  uuid not null references public.contracts(id) on delete cascade,
  term_name    text not null,
  created_at   timestamptz not null default now()
);

create index if not exists idx_custom_key_terms_contract_id on public.custom_key_terms(contract_id);

-- Defense-in-depth: enforce the 5-custom-term cap at the DB layer as well as
-- the application layer (POST /api/contracts/[id]/custom-terms).
create or replace function public.enforce_custom_key_terms_limit()
returns trigger as $$
begin
  if (select count(*) from public.custom_key_terms where contract_id = new.contract_id) >= 5 then
    raise exception 'Maximum of 5 custom key terms per contract';
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists check_custom_key_terms_limit on public.custom_key_terms;
create trigger check_custom_key_terms_limit
  before insert on public.custom_key_terms
  for each row execute function public.enforce_custom_key_terms_limit();

-- One session per contract for MVP — the unique constraint enforces that
-- invariant at the DB level (a race between two concurrent first-messages
-- could otherwise create two sessions and break the app's .maybeSingle() lookup).
create table if not exists public.chat_sessions (
  id           uuid primary key default gen_random_uuid(),
  contract_id  uuid not null references public.contracts(id) on delete cascade,
  created_at   timestamptz not null default now(),
  unique (contract_id)
);

create index if not exists idx_chat_sessions_contract_id on public.chat_sessions(contract_id);

create table if not exists public.chat_messages (
  id                uuid primary key default gen_random_uuid(),
  chat_session_id   uuid not null references public.chat_sessions(id) on delete cascade,
  role              chat_role not null,
  content           text not null,
  page_citation     int,
  created_at        timestamptz not null default now()
);

create index if not exists idx_chat_messages_session_created on public.chat_messages(chat_session_id, created_at);

create table if not exists public.user_feedback (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  contract_id  uuid not null references public.contracts(id) on delete cascade,
  rating       feedback_rating not null,
  comment      text,
  created_at   timestamptz not null default now(),
  unique (user_id, contract_id)
);

create index if not exists idx_user_feedback_contract_id on public.user_feedback(contract_id);

-- ----------------------------------------------------------------------------
-- Views
-- ----------------------------------------------------------------------------

-- Feeds the <=12%-correction-rate monitoring (PRD §8/§10). security_invoker
-- ensures the view is subject to the querying user's RLS on key_terms, not
-- the view owner's.
drop view if exists public.term_corrections;
create view public.term_corrections
with (security_invoker = true)
as
  select * from public.key_terms where is_edited = true;

-- ----------------------------------------------------------------------------
-- updated_at triggers
-- ----------------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists set_contracts_updated_at on public.contracts;
create trigger set_contracts_updated_at
  before update on public.contracts
  for each row execute function public.set_updated_at();

drop trigger if exists set_key_terms_updated_at on public.key_terms;
create trigger set_key_terms_updated_at
  before update on public.key_terms
  for each row execute function public.set_updated_at();

-- ----------------------------------------------------------------------------
-- Row Level Security
-- ----------------------------------------------------------------------------

alter table public.contracts enable row level security;
alter table public.key_terms enable row level security;
alter table public.custom_key_terms enable row level security;
alter table public.chat_sessions enable row level security;
alter table public.chat_messages enable row level security;
alter table public.user_feedback enable row level security;

-- contracts: direct ownership via user_id
drop policy if exists "contracts_select_own" on public.contracts;
create policy "contracts_select_own" on public.contracts
  for select using (auth.uid() = user_id);

drop policy if exists "contracts_insert_own" on public.contracts;
create policy "contracts_insert_own" on public.contracts
  for insert with check (auth.uid() = user_id);

drop policy if exists "contracts_update_own" on public.contracts;
create policy "contracts_update_own" on public.contracts
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "contracts_delete_own" on public.contracts;
create policy "contracts_delete_own" on public.contracts
  for delete using (auth.uid() = user_id);

-- key_terms: ownership via contracts.user_id
drop policy if exists "key_terms_select_own" on public.key_terms;
create policy "key_terms_select_own" on public.key_terms
  for select using (
    exists (select 1 from public.contracts c where c.id = key_terms.contract_id and c.user_id = auth.uid())
  );

drop policy if exists "key_terms_insert_own" on public.key_terms;
create policy "key_terms_insert_own" on public.key_terms
  for insert with check (
    exists (select 1 from public.contracts c where c.id = key_terms.contract_id and c.user_id = auth.uid())
  );

drop policy if exists "key_terms_update_own" on public.key_terms;
create policy "key_terms_update_own" on public.key_terms
  for update using (
    exists (select 1 from public.contracts c where c.id = key_terms.contract_id and c.user_id = auth.uid())
  ) with check (
    exists (select 1 from public.contracts c where c.id = key_terms.contract_id and c.user_id = auth.uid())
  );

drop policy if exists "key_terms_delete_own" on public.key_terms;
create policy "key_terms_delete_own" on public.key_terms
  for delete using (
    exists (select 1 from public.contracts c where c.id = key_terms.contract_id and c.user_id = auth.uid())
  );

-- custom_key_terms: ownership via contracts.user_id
drop policy if exists "custom_key_terms_select_own" on public.custom_key_terms;
create policy "custom_key_terms_select_own" on public.custom_key_terms
  for select using (
    exists (select 1 from public.contracts c where c.id = custom_key_terms.contract_id and c.user_id = auth.uid())
  );

drop policy if exists "custom_key_terms_insert_own" on public.custom_key_terms;
create policy "custom_key_terms_insert_own" on public.custom_key_terms
  for insert with check (
    exists (select 1 from public.contracts c where c.id = custom_key_terms.contract_id and c.user_id = auth.uid())
  );

drop policy if exists "custom_key_terms_delete_own" on public.custom_key_terms;
create policy "custom_key_terms_delete_own" on public.custom_key_terms
  for delete using (
    exists (select 1 from public.contracts c where c.id = custom_key_terms.contract_id and c.user_id = auth.uid())
  );

-- chat_sessions: ownership via contracts.user_id
drop policy if exists "chat_sessions_select_own" on public.chat_sessions;
create policy "chat_sessions_select_own" on public.chat_sessions
  for select using (
    exists (select 1 from public.contracts c where c.id = chat_sessions.contract_id and c.user_id = auth.uid())
  );

drop policy if exists "chat_sessions_insert_own" on public.chat_sessions;
create policy "chat_sessions_insert_own" on public.chat_sessions
  for insert with check (
    exists (select 1 from public.contracts c where c.id = chat_sessions.contract_id and c.user_id = auth.uid())
  );

-- chat_messages: ownership via chat_sessions -> contracts.user_id
drop policy if exists "chat_messages_select_own" on public.chat_messages;
create policy "chat_messages_select_own" on public.chat_messages
  for select using (
    exists (
      select 1 from public.chat_sessions cs
      join public.contracts c on c.id = cs.contract_id
      where cs.id = chat_messages.chat_session_id and c.user_id = auth.uid()
    )
  );

drop policy if exists "chat_messages_insert_own" on public.chat_messages;
create policy "chat_messages_insert_own" on public.chat_messages
  for insert with check (
    exists (
      select 1 from public.chat_sessions cs
      join public.contracts c on c.id = cs.contract_id
      where cs.id = chat_messages.chat_session_id and c.user_id = auth.uid()
    )
  );

-- user_feedback: direct ownership via user_id
drop policy if exists "user_feedback_select_own" on public.user_feedback;
create policy "user_feedback_select_own" on public.user_feedback
  for select using (auth.uid() = user_id);

drop policy if exists "user_feedback_insert_own" on public.user_feedback;
create policy "user_feedback_insert_own" on public.user_feedback
  for insert with check (auth.uid() = user_id);

drop policy if exists "user_feedback_update_own" on public.user_feedback;
create policy "user_feedback_update_own" on public.user_feedback
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ----------------------------------------------------------------------------
-- Storage — bucket + RLS
-- Object path within the `contracts` bucket: {user_id}/{contract_id}/{filename}.pdf
-- (no redundant leading "contracts/" segment — the bucket already provides
-- that namespace, and the RLS policies below check
-- (storage.foldername(name))[1], i.e. the FIRST path segment. A leading
-- "contracts/" segment would shift that check off by one and make every
-- policy evaluate false, silently breaking all uploads/downloads.)
-- ----------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('contracts', 'contracts', false)
on conflict (id) do nothing;

drop policy if exists "contracts_storage_insert_own" on storage.objects;
create policy "contracts_storage_insert_own" on storage.objects
  for insert with check (
    bucket_id = 'contracts'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

drop policy if exists "contracts_storage_select_own" on storage.objects;
create policy "contracts_storage_select_own" on storage.objects
  for select using (
    bucket_id = 'contracts'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

drop policy if exists "contracts_storage_delete_own" on storage.objects;
create policy "contracts_storage_delete_own" on storage.objects
  for delete using (
    bucket_id = 'contracts'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

-- ============================================================================
-- End of schema
-- ============================================================================
