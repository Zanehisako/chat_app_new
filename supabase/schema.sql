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
  check (message_type in ('text', 'image', 'gif', 'voice', 'call'));

alter table public.messages
  drop constraint if exists messages_media_payload_check,
  add constraint messages_media_payload_check
  check (
    (
      message_type in ('text', 'call')
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

create table if not exists public.call_sessions (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  caller_id uuid not null references auth.users (id) on delete cascade,
  callee_id uuid not null references auth.users (id) on delete cascade,
  caller_name text not null default 'Caller',
  is_video boolean not null default true,
  status text not null default 'ringing',
  failure_reason text,
  ended_by_id uuid references auth.users (id) on delete set null,
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

alter table public.messages
  drop constraint if exists messages_message_type_check,
  add constraint messages_message_type_check
  check (message_type in ('text', 'image', 'gif', 'voice', 'call'));

alter table public.messages
  drop constraint if exists messages_media_payload_check,
  add constraint messages_media_payload_check
  check (
    (
      message_type in ('text', 'call')
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

create or replace function public.log_call_started_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.messages (
    conversation_id,
    sender_id,
    sender_name,
    body,
    message_type,
    created_at
  )
  values (
    new.conversation_id,
    new.caller_id,
    new.caller_name,
    new.caller_name || ' started a ' ||
      case when new.is_video then 'video call' else 'voice call' end,
    'call',
    new.created_at
  );

  return new;
end;
$$;

drop trigger if exists on_call_session_started_message on public.call_sessions;
create trigger on_call_session_started_message
  after insert on public.call_sessions
  for each row execute function public.log_call_started_message();

create or replace function public.log_call_finished_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_id uuid;
  actor_name text;
  event_body text;
begin
  if old.status in ('ended', 'rejected', 'failed')
      or new.status not in ('ended', 'rejected', 'failed') then
    return new;
  end if;

  actor_id := coalesce(new.ended_by_id, new.caller_id);

  select profiles.display_name
  into actor_name
  from public.profiles
  where profiles.id = actor_id;

  actor_name := coalesce(nullif(actor_name, ''), new.caller_name, 'Someone');

  event_body := case new.status
    when 'rejected' then actor_name || ' declined the call'
    when 'failed' then 'Call failed'
    else actor_name || ' ended the call'
  end;

  insert into public.messages (
    conversation_id,
    sender_id,
    sender_name,
    body,
    message_type,
    created_at
  )
  values (
    new.conversation_id,
    actor_id,
    actor_name,
    event_body,
    'call',
    coalesce(new.ended_at, now())
  );

  return new;
end;
$$;

drop trigger if exists on_call_session_finished_message on public.call_sessions;
create trigger on_call_session_finished_message
  after update of status on public.call_sessions
  for each row execute function public.log_call_finished_message();

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
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'call_sessions'
  ) then
    alter publication supabase_realtime add table public.call_sessions;
  end if;

  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'call_signal_events'
  ) then
    alter publication supabase_realtime add table public.call_signal_events;
  end if;
end $$;

create extension if not exists pg_net;
create extension if not exists pg_cron;

create table if not exists public.push_device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  provider text not null check (provider in ('fcm', 'wns')),
  token text not null,
  platform text not null,
  device_label text,
  last_seen_at timestamptz not null default now(),
  disabled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint push_device_tokens_provider_token_key unique (provider, token)
);

create table if not exists public.push_notification_jobs (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.messages (id) on delete cascade,
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  recipient_id uuid not null references auth.users (id) on delete cascade,
  sender_id uuid not null references auth.users (id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'sending', 'retry', 'sent', 'dropped', 'failed')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  next_attempt_at timestamptz not null default now(),
  last_attempt_at timestamptz,
  sent_at timestamptz,
  last_error text,
  title text not null,
  body text not null,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint push_notification_jobs_message_recipient_key unique (message_id, recipient_id)
);

create table if not exists public.push_notification_dispatch_config (
  id boolean primary key default true check (id),
  function_url text,
  dispatch_secret text,
  enabled boolean not null default false,
  updated_at timestamptz not null default now()
);

create index if not exists push_device_tokens_user_provider_idx
  on public.push_device_tokens (user_id, provider)
  where disabled_at is null;

create index if not exists push_notification_jobs_pending_idx
  on public.push_notification_jobs (status, next_attempt_at, created_at)
  where status in ('pending', 'retry');

create index if not exists push_notification_jobs_recipient_idx
  on public.push_notification_jobs (recipient_id, created_at desc);

alter table public.push_device_tokens enable row level security;
alter table public.push_notification_jobs enable row level security;
alter table public.push_notification_dispatch_config enable row level security;

drop policy if exists "Users can read own push tokens" on public.push_device_tokens;
create policy "Users can read own push tokens"
  on public.push_device_tokens
  for select
  to authenticated
  using (user_id = auth.uid());

drop policy if exists "Users can register own push tokens" on public.push_device_tokens;
create policy "Users can register own push tokens"
  on public.push_device_tokens
  for insert
  to authenticated
  with check (user_id = auth.uid());

drop policy if exists "Users can refresh own push tokens" on public.push_device_tokens;
create policy "Users can refresh own push tokens"
  on public.push_device_tokens
  for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "Users can delete own push tokens" on public.push_device_tokens;
create policy "Users can delete own push tokens"
  on public.push_device_tokens
  for delete
  to authenticated
  using (user_id = auth.uid());

create or replace function public.push_message_preview(
  message_type text,
  message_body text
)
returns text
language sql
immutable
as $$
  select case
    when nullif(trim(coalesce(message_body, '')), '') is not null
      then left(trim(message_body), 180)
    when message_type = 'image' then 'Sent a photo'
    when message_type = 'gif' then 'Sent a GIF'
    when message_type = 'voice' then 'Sent a voice message'
    when message_type = 'call' then 'Call updated'
    else 'Sent a message'
  end;
$$;

create or replace function public.invoke_push_notification_dispatch()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  config record;
  headers jsonb;
begin
  select *
  into config
  from public.push_notification_dispatch_config
  where id = true
    and enabled = true
    and nullif(function_url, '') is not null;

  if not found then
    return;
  end if;

  headers := jsonb_build_object('Content-Type', 'application/json');
  if nullif(config.dispatch_secret, '') is not null then
    headers := headers || jsonb_build_object(
      'x-dispatch-secret',
      config.dispatch_secret
    );
  end if;

  perform net.http_post(
    url := config.function_url,
    headers := headers,
    body := jsonb_build_object('source', 'database'),
    timeout_milliseconds := 1000
  );
exception
  when others then
    return;
end;
$$;

revoke execute on function public.invoke_push_notification_dispatch()
  from public, anon, authenticated;

create or replace function public.enqueue_push_notification_after_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  target_recipient_id uuid;
  notification_body text;
begin
  select
    case
      when conversations.user_one_id = new.sender_id then conversations.user_two_id
      else conversations.user_one_id
    end
  into target_recipient_id
  from public.conversations
  where conversations.id = new.conversation_id
    and new.sender_id in (conversations.user_one_id, conversations.user_two_id);

  if target_recipient_id is null or target_recipient_id = new.sender_id then
    return new;
  end if;

  notification_body := public.push_message_preview(
    coalesce(new.message_type, 'text'),
    new.body
  );

  insert into public.push_notification_jobs (
    message_id,
    conversation_id,
    recipient_id,
    sender_id,
    title,
    body,
    data
  )
  values (
    new.id,
    new.conversation_id,
    target_recipient_id,
    new.sender_id,
    new.sender_name,
    notification_body,
    jsonb_build_object(
      'type', 'message',
      'message_id', new.id,
      'conversation_id', new.conversation_id,
      'sender_id', new.sender_id,
      'chat_message_type', coalesce(new.message_type, 'text')
    )
  )
  on conflict on constraint push_notification_jobs_message_recipient_key
    do nothing;

  perform public.invoke_push_notification_dispatch();
  return new;
end;
$$;

drop trigger if exists on_message_enqueue_push_notification on public.messages;
create trigger on_message_enqueue_push_notification
  after insert on public.messages
  for each row execute function public.enqueue_push_notification_after_message();

create or replace function public.claim_push_notification_jobs(batch_size integer default 25)
returns table (
  id uuid,
  message_id uuid,
  conversation_id uuid,
  recipient_id uuid,
  sender_id uuid,
  title text,
  body text,
  data jsonb,
  attempt_count integer
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  with claimed as (
    select jobs.id
    from public.push_notification_jobs as jobs
    where (
      jobs.status in ('pending', 'retry')
      and jobs.next_attempt_at <= now()
    ) or (
      jobs.status = 'sending'
      and jobs.last_attempt_at <= now() - interval '15 minutes'
    )
    order by jobs.created_at
    limit least(greatest(coalesce(batch_size, 25), 1), 100)
    for update skip locked
  ),
  updated as (
    update public.push_notification_jobs as jobs
    set status = 'sending',
        attempt_count = jobs.attempt_count + 1,
        last_attempt_at = now(),
        updated_at = now()
    from claimed
    where jobs.id = claimed.id
    returning
      jobs.id,
      jobs.message_id,
      jobs.conversation_id,
      jobs.recipient_id,
      jobs.sender_id,
      jobs.title,
      jobs.body,
      jobs.data,
      jobs.attempt_count
  )
  select
    updated.id,
    updated.message_id,
    updated.conversation_id,
    updated.recipient_id,
    updated.sender_id,
    updated.title,
    updated.body,
    updated.data,
    updated.attempt_count
  from updated;
end;
$$;

revoke all on function public.claim_push_notification_jobs(integer)
  from public, anon, authenticated;
grant execute on function public.claim_push_notification_jobs(integer)
  to service_role;

do $$
declare
  existing_job_id bigint;
begin
  select jobid
  into existing_job_id
  from cron.job
  where jobname = 'dispatch-push-notification-retries';

  if existing_job_id is not null then
    perform cron.unschedule(existing_job_id);
  end if;

  perform cron.schedule(
    'dispatch-push-notification-retries',
    '*/5 * * * *',
    $cron$select public.invoke_push_notification_dispatch();$cron$
  );
end;
$$;

notify pgrst, 'reload schema';

-- Message actions: replies, reactions, editing, soft deletion, and forwarding.
alter table public.messages
  add column if not exists reply_to_message_id uuid,
  add column if not exists is_forwarded boolean not null default false,
  add column if not exists edited_at timestamptz,
  add column if not exists deleted_at timestamptz;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.messages'::regclass
      and conname = 'messages_reply_to_message_id_fkey'
  ) then
    alter table public.messages
      add constraint messages_reply_to_message_id_fkey
      foreign key (reply_to_message_id)
      references public.messages (id)
      on delete set null;
  end if;
end $$;

create index if not exists messages_reply_to_message_id_idx
  on public.messages (reply_to_message_id)
  where reply_to_message_id is not null;

create table if not exists public.message_reactions (
  message_id uuid not null references public.messages (id) on delete cascade,
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  emoji text not null check (char_length(emoji) between 1 and 32),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id, emoji)
);

create index if not exists message_reactions_conversation_idx
  on public.message_reactions (conversation_id, message_id);

create or replace function public.validate_message_reply()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  replied_conversation_id uuid;
  replied_deleted_at timestamptz;
begin
  if new.reply_to_message_id is null then return new; end if;
  if new.reply_to_message_id = new.id then
    raise exception 'A message cannot reply to itself';
  end if;
  select source.conversation_id, source.deleted_at
  into replied_conversation_id, replied_deleted_at
  from public.messages as source
  where source.id = new.reply_to_message_id;
  if replied_conversation_id is null then raise exception 'Reply target does not exist'; end if;
  if replied_conversation_id <> new.conversation_id then
    raise exception 'Reply target must belong to the same conversation';
  end if;
  if replied_deleted_at is not null then raise exception 'Cannot reply to a deleted message'; end if;
  return new;
end;
$$;

drop trigger if exists on_message_validate_reply on public.messages;
create trigger on_message_validate_reply
  before insert or update of reply_to_message_id, conversation_id on public.messages
  for each row execute function public.validate_message_reply();

create or replace function public.edit_message(target_message_id uuid, new_body text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  active_user_id uuid := auth.uid();
  target_type text;
begin
  if active_user_id is null then raise exception 'Authentication required'; end if;
  select message_type into target_type
  from public.messages
  where id = target_message_id and sender_id = active_user_id and deleted_at is null
    and exists (
      select 1 from public.conversations
      where conversations.id = messages.conversation_id
        and active_user_id in (conversations.user_one_id, conversations.user_two_id)
    )
  for update;
  if not found then raise exception 'Message is missing or cannot be edited'; end if;
  if target_type = 'call' then raise exception 'Call events cannot be edited'; end if;
  if target_type = 'text' and nullif(trim(coalesce(new_body, '')), '') is null then
    raise exception 'Text messages cannot be empty';
  end if;
  update public.messages
  set body = trim(coalesce(new_body, '')), edited_at = now()
  where id = target_message_id;
end;
$$;

create or replace function public.delete_message(target_message_id uuid)
returns table (media_bucket text, media_path text)
language plpgsql
security definer
set search_path = public
as $$
declare
  active_user_id uuid := auth.uid();
  stored_bucket text;
  stored_path text;
begin
  if active_user_id is null then raise exception 'Authentication required'; end if;
  select messages.media_bucket, messages.media_path
  into stored_bucket, stored_path
  from public.messages
  where id = target_message_id and sender_id = active_user_id
    and deleted_at is null and message_type <> 'call'
    and exists (
      select 1 from public.conversations
      where conversations.id = messages.conversation_id
        and active_user_id in (conversations.user_one_id, conversations.user_two_id)
    )
  for update;
  if not found then raise exception 'Message is missing or cannot be deleted'; end if;
  delete from public.message_reactions where message_id = target_message_id;
  update public.messages
  set body = '', message_type = 'text', media_bucket = null, media_path = null,
      media_mime_type = null, media_size_bytes = null, media_width = null,
      media_height = null, media_duration_ms = null, media_waveform = null,
      media_original_name = null, reply_to_message_id = null, deleted_at = now()
  where id = target_message_id;
  return query select stored_bucket, stored_path;
end;
$$;

create or replace function public.toggle_message_reaction(
  target_message_id uuid,
  selected_emoji text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  active_user_id uuid := auth.uid();
  target_conversation_id uuid;
  normalized_emoji text := trim(selected_emoji);
begin
  if active_user_id is null then raise exception 'Authentication required'; end if;
  if normalized_emoji is null
    or char_length(normalized_emoji) not between 1 and 32 then
    raise exception 'Choose one valid emoji';
  end if;
  select messages.conversation_id into target_conversation_id
  from public.messages
  join public.conversations on conversations.id = messages.conversation_id
  where messages.id = target_message_id and messages.deleted_at is null
    and active_user_id in (conversations.user_one_id, conversations.user_two_id);
  if target_conversation_id is null then
    raise exception 'Message is missing or cannot be reacted to';
  end if;
  if exists (
    select 1 from public.message_reactions
    where message_id = target_message_id and user_id = active_user_id
      and emoji = normalized_emoji
  ) then
    delete from public.message_reactions
    where message_id = target_message_id and user_id = active_user_id
      and emoji = normalized_emoji;
    return false;
  end if;
  insert into public.message_reactions (message_id, conversation_id, user_id, emoji)
  values (target_message_id, target_conversation_id, active_user_id, normalized_emoji)
  on conflict (message_id, user_id, emoji) do nothing;
  return true;
end;
$$;

alter table public.message_reactions enable row level security;
grant select on table public.message_reactions to authenticated;
drop policy if exists "Conversation members can read message reactions" on public.message_reactions;
create policy "Conversation members can read message reactions"
  on public.message_reactions for select to authenticated
  using (
    exists (
      select 1 from public.conversations
      where conversations.id = message_reactions.conversation_id
        and auth.uid() in (conversations.user_one_id, conversations.user_two_id)
    )
  );

revoke all on function public.edit_message(uuid, text) from public;
revoke all on function public.delete_message(uuid) from public;
revoke all on function public.toggle_message_reaction(uuid, text) from public;
grant execute on function public.edit_message(uuid, text) to authenticated;
grant execute on function public.delete_message(uuid) to authenticated;
grant execute on function public.toggle_message_reaction(uuid, text) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public'
      and tablename = 'message_reactions'
  ) then
    alter publication supabase_realtime add table public.message_reactions;
  end if;
end $$;

notify pgrst, 'reload schema';

-- Push notification delivery reliability (20260710120000).
alter table public.push_device_tokens
  add column if not exists expires_at timestamptz;

alter table public.push_notification_jobs
  drop constraint if exists push_notification_jobs_status_check;

alter table public.push_notification_jobs
  add constraint push_notification_jobs_status_check
  check (status in (
    'pending', 'sending', 'retry', 'sent', 'partial', 'dropped', 'failed'
  ));

alter table public.push_notification_dispatch_config
  drop constraint if exists push_notification_dispatch_config_enabled_check;

-- The earlier migration allowed an enabled row without a secret. Disable that
-- incomplete configuration before enforcing the fail-closed invariant.
update public.push_notification_dispatch_config
set enabled = false,
    updated_at = now()
where enabled
  and (
    function_url !~ '^https://'
    or length(coalesce(dispatch_secret, '')) < 32
  );

alter table public.push_notification_dispatch_config
  add constraint push_notification_dispatch_config_enabled_check
  check (
    not enabled or (
      function_url ~ '^https://'
      and length(coalesce(dispatch_secret, '')) >= 32
    )
  );

drop policy if exists "Users can register own push tokens" on public.push_device_tokens;
drop policy if exists "Users can refresh own push tokens" on public.push_device_tokens;
drop policy if exists "Users can delete own push tokens" on public.push_device_tokens;

create or replace function public.register_push_device_token(
  p_provider text,
  p_token text,
  p_platform text,
  p_device_label text default null,
  p_expires_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
  token_id uuid;
begin
  if current_user_id is null then
    raise exception 'Authentication is required to register a push token';
  end if;
  if p_provider not in ('fcm', 'wns') then
    raise exception 'Unsupported push provider';
  end if;
  if nullif(trim(p_token), '') is null or length(p_token) > 4096 then
    raise exception 'Invalid push token';
  end if;
  if p_provider = 'wns'
    and lower(trim(p_token)) !~ '^https://([a-z0-9-]+\.)*notify\.windows\.com(/|$)' then
    raise exception 'Invalid WNS channel URI';
  end if;
  if nullif(trim(p_platform), '') is null or length(p_platform) > 64 then
    raise exception 'Invalid push platform';
  end if;

  insert into public.push_device_tokens (
    user_id,
    provider,
    token,
    platform,
    device_label,
    expires_at,
    last_seen_at,
    disabled_at,
    updated_at
  )
  values (
    current_user_id,
    p_provider,
    trim(p_token),
    trim(p_platform),
    nullif(trim(p_device_label), ''),
    p_expires_at,
    now(),
    null,
    now()
  )
  on conflict (provider, token) do update
  set user_id = excluded.user_id,
      platform = excluded.platform,
      device_label = excluded.device_label,
      expires_at = excluded.expires_at,
      last_seen_at = now(),
      disabled_at = null,
      updated_at = now()
  returning id into token_id;

  return token_id;
end;
$$;

create or replace function public.unregister_push_device_token(
  p_provider text,
  p_token text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
begin
  if current_user_id is null then
    raise exception 'Authentication is required to unregister a push token';
  end if;

  delete from public.push_device_tokens
  where user_id = current_user_id
    and provider = p_provider
    and token = p_token;

  return found;
end;
$$;

revoke all on function public.register_push_device_token(
  text, text, text, text, timestamptz
) from public, anon;
grant execute on function public.register_push_device_token(
  text, text, text, text, timestamptz
) to authenticated;

revoke all on function public.unregister_push_device_token(text, text)
  from public, anon;
grant execute on function public.unregister_push_device_token(text, text)
  to authenticated;

create table if not exists public.push_notification_deliveries (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.push_notification_jobs (id) on delete cascade,
  device_token_id uuid references public.push_device_tokens (id) on delete set null,
  status text not null default 'pending'
    check (status in ('pending', 'sending', 'retry', 'sent', 'dropped', 'failed')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  next_attempt_at timestamptz not null default now(),
  last_attempt_at timestamptz,
  lease_id uuid,
  lease_expires_at timestamptz,
  sent_at timestamptz,
  provider_message_id text,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint push_notification_deliveries_job_token_key unique (job_id, device_token_id)
);

create index if not exists push_notification_deliveries_due_idx
  on public.push_notification_deliveries (status, next_attempt_at, created_at)
  where status in ('pending', 'retry');

create index if not exists push_notification_deliveries_lease_idx
  on public.push_notification_deliveries (lease_expires_at)
  where status = 'sending';

create or replace function public.snapshot_push_notification_deliveries()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.push_notification_deliveries (
    job_id,
    device_token_id,
    status,
    next_attempt_at
  )
  select
    new.id,
    tokens.id,
    'pending',
    new.next_attempt_at
  from public.push_device_tokens as tokens
  where tokens.user_id = new.recipient_id
    and tokens.disabled_at is null
    and (tokens.expires_at is null or tokens.expires_at > now())
  on conflict (job_id, device_token_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_push_notification_job_snapshot_deliveries
  on public.push_notification_jobs;
create trigger on_push_notification_job_snapshot_deliveries
  after insert on public.push_notification_jobs
  for each row execute function public.snapshot_push_notification_deliveries();

insert into public.push_notification_deliveries (
  job_id,
  device_token_id,
  status,
  attempt_count,
  next_attempt_at,
  last_attempt_at,
  last_error
)
select
  jobs.id,
  tokens.id,
  case
    when jobs.status = 'sending' then 'retry'
    else jobs.status
  end,
  jobs.attempt_count,
  jobs.next_attempt_at,
  jobs.last_attempt_at,
  jobs.last_error
from public.push_notification_jobs as jobs
join public.push_device_tokens as tokens
  on tokens.user_id = jobs.recipient_id
  and tokens.disabled_at is null
  and (tokens.expires_at is null or tokens.expires_at > now())
where jobs.status in ('pending', 'retry', 'sending')
on conflict (job_id, device_token_id) do nothing;

update public.push_notification_jobs
set status = 'retry',
    updated_at = now()
where status = 'sending';

create or replace function public.refresh_push_notification_job(p_job_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  delivery_count integer;
  pending_count integer;
  retry_count integer;
  sending_count integer;
  sent_count integer;
  dropped_count integer;
  failed_count integer;
  max_attempts integer;
  next_attempt timestamptz;
  summary_error text;
  next_status text;
begin
  select
    count(*),
    count(*) filter (where status = 'pending'),
    count(*) filter (where status = 'retry'),
    count(*) filter (where status = 'sending'),
    count(*) filter (where status = 'sent'),
    count(*) filter (where status = 'dropped'),
    count(*) filter (where status = 'failed'),
    coalesce(max(attempt_count), 0),
    min(next_attempt_at) filter (where status in ('pending', 'retry'))
  into
    delivery_count,
    pending_count,
    retry_count,
    sending_count,
    sent_count,
    dropped_count,
    failed_count,
    max_attempts,
    next_attempt
  from public.push_notification_deliveries
  where job_id = p_job_id;

  select left(string_agg(last_error, '; ' order by updated_at desc), 1000)
  into summary_error
  from public.push_notification_deliveries
  where job_id = p_job_id
    and last_error is not null;

  if delivery_count = 0 then
    next_status := 'dropped';
    summary_error := coalesce(summary_error, 'No active push tokens');
  elsif pending_count + retry_count + sending_count > 0 then
    next_status := case
      when sending_count > 0 then 'sending'
      when retry_count > 0 then 'retry'
      else 'pending'
    end;
  elsif sent_count > 0 and (dropped_count + failed_count) > 0 then
    next_status := 'partial';
  elsif sent_count > 0 then
    next_status := 'sent';
  elsif failed_count > 0 then
    next_status := 'failed';
  else
    next_status := 'dropped';
  end if;

  update public.push_notification_jobs
  set status = next_status,
      attempt_count = max_attempts,
      next_attempt_at = coalesce(next_attempt, now()),
      sent_at = case
        when next_status in ('sent', 'partial') then coalesce(sent_at, now())
        else null
      end,
      last_error = summary_error,
      updated_at = now()
  where id = p_job_id;
end;
$$;

create or replace function public.drop_empty_push_notification_jobs()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  changed integer;
begin
  update public.push_notification_jobs as jobs
  set status = 'dropped',
      last_error = 'No active push tokens',
      updated_at = now()
  where jobs.status in ('pending', 'retry')
    and not exists (
      select 1
      from public.push_notification_deliveries as deliveries
      where deliveries.job_id = jobs.id
    );
  get diagnostics changed = row_count;
  return changed;
end;
$$;

drop function if exists public.claim_push_notification_jobs(integer);

create or replace function public.claim_push_notification_deliveries(
  batch_size integer default 25
)
returns table (
  delivery_id uuid,
  lease_id uuid,
  job_id uuid,
  message_id uuid,
  conversation_id uuid,
  recipient_id uuid,
  title text,
  body text,
  data jsonb,
  attempt_count integer,
  token_id uuid,
  provider text,
  token text,
  platform text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  with claimed as (
    select deliveries.id
    from public.push_notification_deliveries as deliveries
    where (
      deliveries.status in ('pending', 'retry')
      and deliveries.next_attempt_at <= now()
    ) or (
      deliveries.status = 'sending'
      and deliveries.lease_expires_at <= now()
    )
    order by deliveries.created_at
    limit least(greatest(coalesce(batch_size, 25), 1), 100)
    for update skip locked
  ),
  updated as (
    update public.push_notification_deliveries as deliveries
    set status = 'sending',
        attempt_count = deliveries.attempt_count + 1,
        last_attempt_at = now(),
        lease_id = gen_random_uuid(),
        lease_expires_at = now() + interval '15 minutes',
        updated_at = now()
    from claimed
    where deliveries.id = claimed.id
    returning
      deliveries.id,
      deliveries.lease_id,
      deliveries.job_id,
      deliveries.attempt_count,
      deliveries.device_token_id
  ),
  touch_jobs as (
    update public.push_notification_jobs as jobs
    set status = 'sending',
        updated_at = now()
    from (select distinct updated.job_id from updated) as touched
    where jobs.id = touched.job_id
    returning jobs.id
  )
  select
    updated.id as delivery_id,
    updated.lease_id,
    jobs.id as job_id,
    jobs.message_id,
    jobs.conversation_id,
    jobs.recipient_id,
    jobs.title,
    jobs.body,
    jobs.data,
    updated.attempt_count,
    tokens.id as token_id,
    tokens.provider,
    tokens.token,
    tokens.platform
  from updated
  join public.push_notification_jobs as jobs on jobs.id = updated.job_id
  left join public.push_device_tokens as tokens
    on tokens.id = updated.device_token_id
    and tokens.user_id = jobs.recipient_id
    and tokens.disabled_at is null
    and (tokens.expires_at is null or tokens.expires_at > now());
end;
$$;

revoke all on function public.claim_push_notification_deliveries(integer)
  from public, anon, authenticated;
grant execute on function public.claim_push_notification_deliveries(integer)
  to service_role;

revoke all on function public.refresh_push_notification_job(uuid)
  from public, anon, authenticated;
grant execute on function public.refresh_push_notification_job(uuid)
  to service_role;

revoke all on function public.drop_empty_push_notification_jobs()
  from public, anon, authenticated;
grant execute on function public.drop_empty_push_notification_jobs()
  to service_role;

create or replace function public.invoke_push_notification_dispatch()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  config record;
begin
  select *
  into config
  from public.push_notification_dispatch_config
  where id = true
    and enabled = true
    and function_url ~ '^https://'
    and length(coalesce(dispatch_secret, '')) >= 32;

  if not found then
    return;
  end if;

  perform net.http_post(
    url := config.function_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-dispatch-secret', config.dispatch_secret
    ),
    body := jsonb_build_object('source', 'database'),
    timeout_milliseconds := 1000
  );
exception
  when others then
    return;
end;
$$;

notify pgrst, 'reload schema';
