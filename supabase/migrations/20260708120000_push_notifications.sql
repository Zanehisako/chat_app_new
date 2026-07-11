create extension if not exists pgcrypto;
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
  recipient_id uuid;
  notification_body text;
begin
  select
    case
      when conversations.user_one_id = new.sender_id then conversations.user_two_id
      else conversations.user_one_id
    end
  into recipient_id
  from public.conversations
  where conversations.id = new.conversation_id
    and new.sender_id in (conversations.user_one_id, conversations.user_two_id);

  if recipient_id is null or recipient_id = new.sender_id then
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
    recipient_id,
    new.sender_id,
    new.sender_name,
    notification_body,
    jsonb_build_object(
      'type', 'message',
      'message_id', new.id,
      'conversation_id', new.conversation_id,
      'sender_id', new.sender_id,
      'message_type', coalesce(new.message_type, 'text')
    )
  )
  on conflict (message_id, recipient_id) do nothing;

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
