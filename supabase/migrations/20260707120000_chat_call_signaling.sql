create table if not exists public.call_sessions (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  caller_id uuid not null references auth.users (id) on delete cascade,
  callee_id uuid not null references auth.users (id) on delete cascade,
  caller_name text not null default 'Caller',
  is_video boolean not null default true,
  status text not null default 'ringing',
  failure_reason text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  accepted_at timestamptz,
  ended_at timestamptz,
  constraint call_sessions_distinct_users_check check (caller_id <> callee_id),
  constraint call_sessions_status_check check (
    status in ('ringing', 'accepted', 'ended', 'rejected', 'failed')
  )
);

create table if not exists public.call_signal_events (
  id uuid primary key default gen_random_uuid(),
  call_id uuid not null references public.call_sessions (id) on delete cascade,
  sender_id uuid not null references auth.users (id) on delete cascade,
  event_type text not null,
  sdp text,
  sdp_type text,
  candidate text,
  sdp_mid text,
  sdp_m_line_index integer,
  created_at timestamptz not null default now(),
  constraint call_signal_events_type_check check (
    event_type in ('offer', 'answer', 'ice_candidate', 'hangup', 'reject')
  ),
  constraint call_signal_events_payload_check check (
    (
      event_type in ('offer', 'answer')
      and sdp is not null
      and sdp_type in ('offer', 'answer')
      and candidate is null
    )
    or (
      event_type = 'ice_candidate'
      and candidate is not null
      and sdp is null
      and sdp_type is null
    )
    or (
      event_type in ('hangup', 'reject')
      and sdp is null
      and sdp_type is null
      and candidate is null
    )
  )
);

create index if not exists call_sessions_conversation_created_idx
  on public.call_sessions (conversation_id, created_at desc);

create index if not exists call_sessions_callee_status_idx
  on public.call_sessions (callee_id, status, created_at desc);

create index if not exists call_signal_events_call_created_idx
  on public.call_signal_events (call_id, created_at);

alter table public.call_sessions enable row level security;
alter table public.call_signal_events enable row level security;

drop policy if exists "Conversation members can read call sessions"
  on public.call_sessions;
create policy "Conversation members can read call sessions"
  on public.call_sessions
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.conversations
      where conversations.id = call_sessions.conversation_id
        and auth.uid() in (conversations.user_one_id, conversations.user_two_id)
    )
  );

drop policy if exists "Conversation members can create call sessions"
  on public.call_sessions;
create policy "Conversation members can create call sessions"
  on public.call_sessions
  for insert
  to authenticated
  with check (
    caller_id = auth.uid()
    and status = 'ringing'
    and exists (
      select 1
      from public.conversations
      where conversations.id = call_sessions.conversation_id
        and caller_id in (conversations.user_one_id, conversations.user_two_id)
        and callee_id in (conversations.user_one_id, conversations.user_two_id)
    )
  );

drop policy if exists "Conversation members can update own call sessions"
  on public.call_sessions;
create policy "Conversation members can update own call sessions"
  on public.call_sessions
  for update
  to authenticated
  using (
    auth.uid() in (caller_id, callee_id)
    and exists (
      select 1
      from public.conversations
      where conversations.id = call_sessions.conversation_id
        and auth.uid() in (conversations.user_one_id, conversations.user_two_id)
    )
  )
  with check (
    auth.uid() in (caller_id, callee_id)
    and exists (
      select 1
      from public.conversations
      where conversations.id = call_sessions.conversation_id
        and auth.uid() in (conversations.user_one_id, conversations.user_two_id)
    )
  );

drop policy if exists "Conversation members can read call signal events"
  on public.call_signal_events;
create policy "Conversation members can read call signal events"
  on public.call_signal_events
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.call_sessions
      join public.conversations
        on conversations.id = call_sessions.conversation_id
      where call_sessions.id = call_signal_events.call_id
        and auth.uid() in (conversations.user_one_id, conversations.user_two_id)
    )
  );

drop policy if exists "Conversation members can create call signal events"
  on public.call_signal_events;
create policy "Conversation members can create call signal events"
  on public.call_signal_events
  for insert
  to authenticated
  with check (
    sender_id = auth.uid()
    and exists (
      select 1
      from public.call_sessions
      join public.conversations
        on conversations.id = call_sessions.conversation_id
      where call_sessions.id = call_signal_events.call_id
        and auth.uid() in (conversations.user_one_id, conversations.user_two_id)
    )
  );

do $$
begin
  if exists (
    select 1
    from pg_publication
    where pubname = 'supabase_realtime'
  ) and not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'call_sessions'
  ) then
    alter publication supabase_realtime add table public.call_sessions;
  end if;

  if exists (
    select 1
    from pg_publication
    where pubname = 'supabase_realtime'
  ) and not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'call_signal_events'
  ) then
    alter publication supabase_realtime add table public.call_signal_events;
  end if;
end
$$;
