create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  thread_id text not null,
  sender_id text not null,
  sender_name text not null,
  body text not null,
  created_at timestamptz not null default now()
);

create index if not exists messages_thread_created_at_idx
  on public.messages (thread_id, created_at);

alter table public.messages enable row level security;

drop policy if exists "Authenticated users can read messages" on public.messages;
create policy "Authenticated users can read messages"
  on public.messages
  for select
  to authenticated
  using (true);

drop policy if exists "Authenticated users can send own messages" on public.messages;
create policy "Authenticated users can send own messages"
  on public.messages
  for insert
  to authenticated
  with check (sender_id = auth.uid()::text);

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;
end $$;
