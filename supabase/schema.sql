create extension if not exists pgcrypto;

drop table if exists public.messages cascade;

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null default 'Unknown user',
  email text,
  phone text,
  updated_at timestamptz not null default now()
);

create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  user_one_id uuid not null references auth.users (id) on delete cascade,
  user_two_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_message_at timestamptz,
  constraint conversations_distinct_users_check check (user_one_id <> user_two_id),
  constraint conversations_sorted_users_check check (user_one_id < user_two_id),
  constraint conversations_unique_direct_pair_key unique (user_one_id, user_two_id)
);

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  sender_id uuid not null references auth.users (id) on delete cascade,
  sender_name text not null,
  body text not null,
  created_at timestamptz not null default now()
);

create index if not exists profiles_display_name_idx
  on public.profiles (lower(display_name));

create index if not exists conversations_user_one_idx
  on public.conversations (user_one_id, last_message_at desc);

create index if not exists conversations_user_two_idx
  on public.conversations (user_two_id, last_message_at desc);

create index if not exists messages_conversation_created_at_idx
  on public.messages (conversation_id, created_at);

create or replace function public.handle_new_user_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, email, phone)
  values (
    new.id,
    coalesce(
      nullif(new.raw_user_meta_data ->> 'display_name', ''),
      nullif(new.raw_user_meta_data ->> 'full_name', ''),
      nullif(new.raw_user_meta_data ->> 'name', ''),
      nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
      coalesce(new.phone, 'Unknown user')
    ),
    new.email,
    new.phone
  )
  on conflict (id) do update
    set display_name = excluded.display_name,
        email = excluded.email,
        phone = excluded.phone,
        updated_at = now();

  return new;
end;
$$;

drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile
  after insert on auth.users
  for each row execute function public.handle_new_user_profile();

insert into public.profiles (id, display_name, email, phone)
select
  auth_user.id,
  coalesce(
    nullif(auth_user.raw_user_meta_data ->> 'display_name', ''),
    nullif(auth_user.raw_user_meta_data ->> 'full_name', ''),
    nullif(auth_user.raw_user_meta_data ->> 'name', ''),
    nullif(split_part(coalesce(auth_user.email, ''), '@', 1), ''),
    coalesce(auth_user.phone, 'Unknown user')
  ),
  auth_user.email,
  auth_user.phone
from auth.users as auth_user
on conflict (id) do update
  set display_name = excluded.display_name,
      email = excluded.email,
      phone = excluded.phone,
      updated_at = now();

create or replace function public.touch_conversation_after_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.conversations
  set last_message_at = new.created_at,
      updated_at = now()
  where id = new.conversation_id;

  return new;
end;
$$;

drop trigger if exists on_message_touch_conversation on public.messages;
create trigger on_message_touch_conversation
  after insert on public.messages
  for each row execute function public.touch_conversation_after_message();

alter table public.profiles enable row level security;
alter table public.conversations enable row level security;
alter table public.messages enable row level security;

drop policy if exists "Authenticated users can search profiles" on public.profiles;
create policy "Authenticated users can search profiles"
  on public.profiles
  for select
  to authenticated
  using (true);

drop policy if exists "Users can insert own profile" on public.profiles;
create policy "Users can insert own profile"
  on public.profiles
  for insert
  to authenticated
  with check (id = auth.uid());

drop policy if exists "Users can update own profile" on public.profiles;
create policy "Users can update own profile"
  on public.profiles
  for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

drop policy if exists "Users can read own conversations" on public.conversations;
create policy "Users can read own conversations"
  on public.conversations
  for select
  to authenticated
  using (auth.uid() in (user_one_id, user_two_id));

drop policy if exists "Users can create own direct conversations" on public.conversations;
create policy "Users can create own direct conversations"
  on public.conversations
  for insert
  to authenticated
  with check (auth.uid() in (user_one_id, user_two_id));

drop policy if exists "Users can read own conversation messages" on public.messages;
create policy "Users can read own conversation messages"
  on public.messages
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.conversations
      where conversations.id = messages.conversation_id
        and auth.uid() in (conversations.user_one_id, conversations.user_two_id)
    )
  );

drop policy if exists "Users can send own conversation messages" on public.messages;
create policy "Users can send own conversation messages"
  on public.messages
  for insert
  to authenticated
  with check (
    sender_id = auth.uid()
    and exists (
      select 1
      from public.conversations
      where conversations.id = messages.conversation_id
        and auth.uid() in (conversations.user_one_id, conversations.user_two_id)
    )
  );

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'conversations'
  ) then
    alter publication supabase_realtime add table public.conversations;
  end if;

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
