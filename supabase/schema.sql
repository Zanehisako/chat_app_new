create extension if not exists pgcrypto;

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'chat-media',
  'chat-media',
  false,
  15728640,
  array[
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/gif',
    'image/heic',
    'image/heif',
    'audio/wav',
    'audio/x-wav',
    'audio/aac',
    'audio/mpeg',
    'audio/mp3',
    'audio/mp4',
    'audio/webm',
    'audio/ogg'
  ]::text[]
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null default 'Unknown user',
  email text,
  phone text,
  last_seen_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.profiles
  add column if not exists last_seen_at timestamptz;

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

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  sender_id uuid not null references auth.users (id) on delete cascade,
  sender_name text not null,
  body text default '',
  message_type text not null default 'text',
  media_bucket text,
  media_path text,
  media_mime_type text,
  media_size_bytes bigint,
  media_width integer,
  media_height integer,
  media_duration_ms integer,
  media_waveform jsonb,
  media_original_name text,
  created_at timestamptz not null default now()
);

alter table public.messages
  alter column body drop not null,
  alter column body set default '',
  add column if not exists message_type text not null default 'text',
  add column if not exists media_bucket text,
  add column if not exists media_path text,
  add column if not exists media_mime_type text,
  add column if not exists media_size_bytes bigint,
  add column if not exists media_width integer,
  add column if not exists media_height integer,
  add column if not exists media_duration_ms integer,
  add column if not exists media_waveform jsonb,
  add column if not exists media_original_name text;

alter table public.messages
  drop constraint if exists messages_message_type_check,
  add constraint messages_message_type_check
  check (message_type in ('text', 'image', 'gif', 'voice'));

alter table public.messages
  drop constraint if exists messages_media_payload_check,
  add constraint messages_media_payload_check
  check (
    (
      message_type = 'text'
      and media_bucket is null
      and media_path is null
      and media_mime_type is null
      and media_size_bytes is null
      and media_width is null
      and media_height is null
      and media_duration_ms is null
      and media_waveform is null
    )
    or (
      message_type in ('image', 'gif')
      and media_bucket = 'chat-media'
      and media_path is not null
      and media_mime_type like 'image/%'
      and media_size_bytes between 1 and 15728640
      and media_duration_ms is null
      and media_waveform is null
    )
    or (
      message_type = 'voice'
      and media_bucket = 'chat-media'
      and media_path is not null
      and media_mime_type like 'audio/%'
      and media_size_bytes between 1 and 15728640
      and (media_duration_ms is null or media_duration_ms between 0 and 3600000)
      and (media_waveform is null or jsonb_typeof(media_waveform) = 'array')
    )
  );

create table if not exists public.message_receipts (
  message_id uuid not null references public.messages (id) on delete cascade,
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  delivered_at timestamptz,
  read_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (message_id, user_id)
);

create index if not exists profiles_display_name_idx
  on public.profiles (lower(display_name));

create index if not exists conversations_user_one_idx
  on public.conversations (user_one_id, last_message_at desc);

create index if not exists conversations_user_two_idx
  on public.conversations (user_two_id, last_message_at desc);

create index if not exists messages_conversation_created_at_idx
  on public.messages (conversation_id, created_at);

create index if not exists messages_media_path_idx
  on public.messages (media_bucket, media_path)
  where media_path is not null;

create index if not exists message_receipts_conversation_user_idx
  on public.message_receipts (conversation_id, user_id);

create index if not exists message_receipts_user_read_idx
  on public.message_receipts (user_id, read_at);

create or replace function public.handle_new_user_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, email, phone, last_seen_at)
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
    new.phone,
    now()
  )
  on conflict (id) do update
    set display_name = excluded.display_name,
        email = excluded.email,
        phone = excluded.phone,
        last_seen_at = coalesce(profiles.last_seen_at, excluded.last_seen_at),
        updated_at = now();

  return new;
end;
$$;

drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile
  after insert on auth.users
  for each row execute function public.handle_new_user_profile();

insert into public.profiles (id, display_name, email, phone, last_seen_at)
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
  auth_user.phone,
  now()
from auth.users as auth_user
on conflict (id) do update
  set display_name = excluded.display_name,
      email = excluded.email,
      phone = excluded.phone,
      last_seen_at = coalesce(profiles.last_seen_at, excluded.last_seen_at),
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

create or replace function public.create_receipt_after_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  recipient_id uuid;
begin
  select
    case
      when conversations.user_one_id = new.sender_id then conversations.user_two_id
      else conversations.user_one_id
    end
  into recipient_id
  from public.conversations
  where conversations.id = new.conversation_id;

  if recipient_id is not null then
    insert into public.message_receipts (
      message_id,
      conversation_id,
      user_id
    )
    values (
      new.id,
      new.conversation_id,
      recipient_id
    )
    on conflict (message_id, user_id) do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists on_message_create_receipt on public.messages;
create trigger on_message_create_receipt
  after insert on public.messages
  for each row execute function public.create_receipt_after_message();

insert into public.message_receipts (message_id, conversation_id, user_id)
select
  messages.id,
  messages.conversation_id,
  case
    when conversations.user_one_id = messages.sender_id then conversations.user_two_id
    else conversations.user_one_id
  end as user_id
from public.messages
join public.conversations
  on conversations.id = messages.conversation_id
where messages.sender_id in (conversations.user_one_id, conversations.user_two_id)
on conflict (message_id, user_id) do nothing;

alter table public.profiles enable row level security;
alter table public.conversations enable row level security;
alter table public.messages enable row level security;
alter table public.message_receipts enable row level security;

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

drop policy if exists "Conversation members can read chat media" on storage.objects;
create policy "Conversation members can read chat media"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'chat-media'
    and exists (
      select 1
      from public.conversations
      where conversations.id::text = (storage.foldername(name))[1]
        and auth.uid() in (conversations.user_one_id, conversations.user_two_id)
    )
  );

drop policy if exists "Conversation senders can upload chat media" on storage.objects;
create policy "Conversation senders can upload chat media"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'chat-media'
    and (storage.foldername(name))[2] = auth.uid()::text
    and exists (
      select 1
      from public.conversations
      where conversations.id::text = (storage.foldername(name))[1]
        and auth.uid() in (conversations.user_one_id, conversations.user_two_id)
    )
  );

drop policy if exists "Conversation senders can delete chat media" on storage.objects;
create policy "Conversation senders can delete chat media"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'chat-media'
    and (storage.foldername(name))[2] = auth.uid()::text
    and exists (
      select 1
      from public.conversations
      where conversations.id::text = (storage.foldername(name))[1]
        and auth.uid() in (conversations.user_one_id, conversations.user_two_id)
    )
  );

drop policy if exists "Users can read own conversation receipts" on public.message_receipts;
create policy "Users can read own conversation receipts"
  on public.message_receipts
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.conversations
      where conversations.id = message_receipts.conversation_id
        and auth.uid() in (conversations.user_one_id, conversations.user_two_id)
    )
  );

drop policy if exists "Users can update their own receipts" on public.message_receipts;
create policy "Users can update their own receipts"
  on public.message_receipts
  for update
  to authenticated
  using (
    user_id = auth.uid()
    and exists (
      select 1
      from public.conversations
      where conversations.id = message_receipts.conversation_id
        and auth.uid() in (conversations.user_one_id, conversations.user_two_id)
    )
  )
  with check (
    user_id = auth.uid()
    and exists (
      select 1
      from public.conversations
      where conversations.id = message_receipts.conversation_id
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

  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'message_receipts'
  ) then
    alter publication supabase_realtime add table public.message_receipts;
  end if;
end $$;

notify pgrst, 'reload schema';
