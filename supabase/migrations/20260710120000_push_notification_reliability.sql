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
