-- Self-hosted LiveKit group-call control plane.
-- Media stays in LiveKit; Supabase owns authorization, lifecycle, history,
-- invitations, and removal jobs.

alter table public.messages
  add column if not exists group_call_session_id uuid,
  add column if not exists call_event text;

alter table public.messages
  drop constraint if exists messages_call_event_check;

alter table public.messages
  add constraint messages_call_event_check check (
    call_event is null or call_event in ('started', 'ended', 'failed')
  );

create table if not exists public.group_call_sessions (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  started_by uuid not null references auth.users (id) on delete cascade,
  started_by_name text not null default 'Someone',
  title text not null,
  room_name text not null unique,
  is_video boolean not null default true,
  status text not null default 'active',
  ended_by_id uuid references auth.users (id) on delete set null,
  ended_reason text,
  created_at timestamptz not null default now(),
  ended_at timestamptz,
  constraint group_call_sessions_status_check check (
    status in ('active', 'ended', 'failed')
  ),
  constraint group_call_sessions_ended_state_check check (
    (status = 'active' and ended_at is null)
    or (status <> 'active' and ended_at is not null)
  )
);

create unique index if not exists group_call_sessions_one_active_idx
  on public.group_call_sessions (conversation_id)
  where status = 'active';

alter table public.messages
  drop constraint if exists messages_group_call_session_fkey;
alter table public.messages
  add constraint messages_group_call_session_fkey
  foreign key (group_call_session_id)
  references public.group_call_sessions (id)
  on delete set null;

create index if not exists group_call_sessions_conversation_created_idx
  on public.group_call_sessions (conversation_id, created_at desc);

create table if not exists public.group_call_participants (
  call_id uuid not null references public.group_call_sessions (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  status text not null default 'invited',
  invited_at timestamptz not null default now(),
  joined_at timestamptz,
  left_at timestamptz,
  last_seen_at timestamptz,
  primary key (call_id, user_id),
  constraint group_call_participants_status_check check (
    status in ('invited', 'joining', 'joined', 'declined', 'left', 'removed', 'failed')
  ),
  constraint group_call_participants_period_check check (
    left_at is null or joined_at is null or left_at >= joined_at
  )
);

create index if not exists group_call_participants_user_active_idx
  on public.group_call_participants (user_id, call_id)
  where status in ('invited', 'joining', 'joined');

create index if not exists group_call_participants_call_status_idx
  on public.group_call_participants (call_id, status);

create table if not exists public.group_call_webhook_events (
  id text primary key,
  event_name text not null,
  call_id uuid references public.group_call_sessions (id) on delete cascade,
  received_at timestamptz not null default now()
);

create table if not exists public.group_call_control_jobs (
  id uuid primary key default gen_random_uuid(),
  call_id uuid not null references public.group_call_sessions (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  action text not null default 'remove',
  status text not null default 'pending',
  attempts integer not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint group_call_control_jobs_action_check check (action = 'remove'),
  constraint group_call_control_jobs_status_check check (
    status in ('pending', 'sending', 'retry', 'done', 'failed')
  ),
  constraint group_call_control_jobs_unique_key unique (call_id, user_id, action)
);

create index if not exists group_call_control_jobs_due_idx
  on public.group_call_control_jobs (status, next_attempt_at, created_at)
  where status in ('pending', 'retry');

alter table public.group_call_sessions enable row level security;
alter table public.group_call_participants enable row level security;
alter table public.group_call_webhook_events enable row level security;
alter table public.group_call_control_jobs enable row level security;

drop policy if exists "Active members can read group call sessions"
  on public.group_call_sessions;
create policy "Active members can read group call sessions"
  on public.group_call_sessions
  for select
  to authenticated
  using (
    status = 'active'
    and public.is_conversation_member(conversation_id, auth.uid())
  );

drop policy if exists "Active members can read group call participants"
  on public.group_call_participants;
create policy "Active members can read group call participants"
  on public.group_call_participants
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.group_call_sessions as sessions
      where sessions.id = group_call_participants.call_id
        and sessions.status = 'active'
        and public.is_conversation_member(sessions.conversation_id, auth.uid())
    )
  );

grant select on table public.group_call_sessions to authenticated;
grant select on table public.group_call_participants to authenticated;

create or replace function public.start_group_call(
  target_conversation_id uuid,
  target_is_video boolean default true
)
returns public.group_call_sessions
language plpgsql
security definer
set search_path = public
as $$
declare
  active_user_id uuid := auth.uid();
  conversation_record public.conversations;
  existing_call public.group_call_sessions;
  created_call public.group_call_sessions;
  caller_name text;
begin
  if active_user_id is null then
    raise exception 'Authentication required';
  end if;

  select * into conversation_record
  from public.conversations
  where id = target_conversation_id
  for update;

  if not found or conversation_record.conversation_type <> 'group' then
    raise exception 'Only group conversations can start group calls';
  end if;
  if not public.is_conversation_member(target_conversation_id, active_user_id) then
    raise exception 'You are not an active group member';
  end if;
  if (
    select count(*)
    from public.conversation_members
    where conversation_id = target_conversation_id and left_at is null
  ) > 50 then
    raise exception 'Group calls support at most 50 participants';
  end if;

  select * into existing_call
  from public.group_call_sessions
  where conversation_id = target_conversation_id
    and status = 'active'
  for update;

  if found then
    return existing_call;
  end if;

  select coalesce(nullif(trim(display_name), ''), 'Someone')
  into caller_name
  from public.profiles
  where id = active_user_id;
  caller_name := coalesce(caller_name, 'Someone');

  insert into public.group_call_sessions (
    conversation_id,
    started_by,
    started_by_name,
    title,
    room_name,
    is_video
  ) values (
    target_conversation_id,
    active_user_id,
    caller_name,
    coalesce(nullif(trim(conversation_record.title), ''), 'Group'),
    'chat-group-' || gen_random_uuid()::text,
    coalesce(target_is_video, true)
  ) returning * into created_call;

  insert into public.group_call_participants (call_id, user_id, status, last_seen_at)
  select created_call.id, members.user_id,
    case when members.user_id = active_user_id then 'joining' else 'invited' end,
    case when members.user_id = active_user_id then now() else null end
  from public.conversation_members as members
  where members.conversation_id = target_conversation_id
    and members.left_at is null
    and members.joined_at <= created_call.created_at;

  return created_call;
end;
$$;

create or replace function public.join_group_call(target_call_id uuid)
returns public.group_call_sessions
language plpgsql
security definer
set search_path = public
as $$
declare
  active_user_id uuid := auth.uid();
  call_record public.group_call_sessions;
begin
  if active_user_id is null then
    raise exception 'Authentication required';
  end if;

  select sessions.* into call_record
  from public.group_call_sessions as sessions
  where sessions.id = target_call_id
    and sessions.status = 'active'
  for update;

  if not found then
    raise exception 'That group call is no longer active';
  end if;
  if not public.is_conversation_member(call_record.conversation_id, active_user_id) then
    raise exception 'You are not an active group member';
  end if;
  if exists (
    select 1
    from public.group_call_participants
    where call_id = target_call_id
      and user_id = active_user_id
      and status = 'removed'
  ) then
    raise exception 'You were removed from this group call';
  end if;

  insert into public.group_call_participants (
    call_id, user_id, status, invited_at, joined_at, left_at, last_seen_at
  ) values (
    target_call_id, active_user_id, 'joining', now(), null, null, now()
  )
  on conflict (call_id, user_id) do update
    set status = 'joining', left_at = null, last_seen_at = now()
    where group_call_participants.status <> 'removed';

  return call_record;
end;
$$;

create or replace function public.decline_group_call(target_call_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.group_call_participants as participants
  set status = 'declined', left_at = now(), last_seen_at = null
  from public.group_call_sessions as sessions
  where participants.call_id = target_call_id
    and participants.user_id = auth.uid()
    and sessions.id = participants.call_id
    and sessions.status = 'active'
    and public.is_conversation_member(sessions.conversation_id, auth.uid())
    and participants.status in ('invited', 'joining');
end;
$$;

create or replace function public.leave_group_call(target_call_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  active_user_id uuid := auth.uid();
  call_conversation_id uuid;
begin
  select conversation_id into call_conversation_id
  from public.group_call_sessions
  where id = target_call_id and status = 'active';

  if call_conversation_id is null then
    return;
  end if;
  if not public.is_conversation_member(call_conversation_id, active_user_id)
      and not exists (
        select 1 from public.group_call_participants
        where call_id = target_call_id and user_id = active_user_id
      ) then
    raise exception 'You are not part of this group call';
  end if;

  update public.group_call_participants
  set status = 'left', left_at = now(), last_seen_at = null
  where call_id = target_call_id
    and user_id = active_user_id
    and status in ('joining', 'joined');

  if not exists (
    select 1 from public.group_call_participants
    where call_id = target_call_id and status in ('joining', 'joined')
  ) then
    update public.group_call_sessions
    set status = 'ended', ended_at = now(), ended_by_id = active_user_id,
        ended_reason = 'last_participant_left'
    where id = target_call_id and status = 'active';
  end if;
end;
$$;

create or replace function public.fail_group_call(
  target_call_id uuid,
  reason text default 'client_failure'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  active_user_id uuid := auth.uid();
begin
  if not exists (
    select 1
    from public.group_call_sessions
    where id = target_call_id
      and status = 'active'
      and public.is_conversation_member(conversation_id, active_user_id)
  ) then
    raise exception 'That group call is not active';
  end if;

  update public.group_call_participants
  set status = 'failed', left_at = now(), last_seen_at = null
  where call_id = target_call_id
    and user_id = active_user_id
    and status in ('joining', 'joined');

  if not exists (
    select 1 from public.group_call_participants
    where call_id = target_call_id and status in ('joining', 'joined')
  ) then
    update public.group_call_sessions
    set status = 'failed', ended_at = now(), ended_by_id = active_user_id,
        ended_reason = left(trim(coalesce(reason, 'client_failure')), 240)
    where id = target_call_id and status = 'active';
  end if;
end;
$$;

create or replace function public.apply_group_call_participant_event(
  target_call_id uuid,
  target_user_id uuid,
  target_event text,
  target_event_at timestamptz default now()
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  next_status text;
begin
  next_status := case target_event
    when 'participant_joined' then 'joined'
    when 'participant_left' then 'left'
    when 'participant_connection_aborted' then 'failed'
    else null
  end;
  if next_status is null then
    return;
  end if;

  update public.group_call_participants
  set status = case
        when status = 'removed' then 'removed'
        when status in ('left', 'failed', 'declined') then status
        else next_status
      end,
      joined_at = case
        when next_status = 'joined' and joined_at is null then target_event_at
        else joined_at
      end,
      left_at = case
        when next_status in ('left', 'failed') then target_event_at
        else left_at
      end,
      last_seen_at = case
        when next_status = 'joined' and status in ('joining', 'joined')
          then target_event_at
        else null
      end
  where call_id = target_call_id and user_id = target_user_id;

  if target_event in ('participant_left', 'participant_connection_aborted')
      and not exists (
        select 1 from public.group_call_participants
        where call_id = target_call_id and status in ('joining', 'joined')
      ) then
    update public.group_call_sessions
    set status = 'ended', ended_at = coalesce(target_event_at, now()),
        ended_reason = 'last_participant_left'
    where id = target_call_id and status = 'active';
  end if;
end;
$$;

create or replace function public.apply_group_call_room_finished(
  target_call_id uuid,
  reason text default 'room_finished'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.group_call_sessions
  set status = 'ended', ended_at = coalesce(ended_at, now()),
      ended_reason = left(trim(coalesce(reason, 'room_finished')), 240)
  where id = target_call_id and status = 'active';

  update public.group_call_participants
  set status = case when status = 'removed' then 'removed' else 'left' end,
      left_at = coalesce(left_at, now()), last_seen_at = null
  where call_id = target_call_id and status in ('joining', 'joined');
end;
$$;

create or replace function public.enqueue_group_call_member_removal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.left_at is null and new.left_at is not null then
    insert into public.group_call_control_jobs (call_id, user_id, action)
    select participants.call_id, new.user_id, 'remove'
    from public.group_call_participants as participants
    join public.group_call_sessions as sessions
      on sessions.id = participants.call_id
    where participants.user_id = new.user_id
      and sessions.conversation_id = new.conversation_id
      and sessions.status = 'active'
      and participants.status in ('joining', 'joined')
    on conflict (call_id, user_id, action) do nothing;

    -- Mark every outstanding invitation as removed too. If the member is
    -- later re-added, join_group_call must not resurrect this call entry.
    update public.group_call_participants
    set status = 'removed', left_at = coalesce(left_at, new.left_at),
        last_seen_at = null
    where user_id = new.user_id
      and status <> 'removed'
      and exists (
        select 1 from public.group_call_sessions
        where group_call_sessions.id = group_call_participants.call_id
          and group_call_sessions.status = 'active'
          and group_call_sessions.conversation_id = new.conversation_id
      );
  end if;
  return new;
end;
$$;

drop trigger if exists on_group_call_member_removal on public.conversation_members;
create trigger on_group_call_member_removal
  after update of left_at on public.conversation_members
  for each row execute function public.enqueue_group_call_member_removal();

create or replace function public.log_group_call_started_message()
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
    group_call_session_id,
    call_event,
    created_at
  ) values (
    new.conversation_id,
    new.started_by,
    new.started_by_name,
    new.started_by_name || ' started a ' ||
      case when new.is_video then 'video call' else 'voice call' end,
    'call',
    new.id,
    'started',
    new.created_at
  );
  return new;
end;
$$;

drop trigger if exists on_group_call_started_message on public.group_call_sessions;
create trigger on_group_call_started_message
  after insert on public.group_call_sessions
  for each row execute function public.log_group_call_started_message();

create or replace function public.log_group_call_finished_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_id uuid := coalesce(new.ended_by_id, new.started_by);
  actor_name text := coalesce(nullif(new.started_by_name, ''), 'Someone');
  event_body text;
begin
  if old.status <> 'active' or new.status = 'active' then
    return new;
  end if;

  select coalesce(nullif(trim(display_name), ''), actor_name)
  into actor_name
  from public.profiles
  where id = actor_id;
  actor_name := coalesce(actor_name, nullif(new.started_by_name, ''), 'Someone');

  event_body := case new.status
    when 'failed' then 'Group call failed'
    else actor_name || ' ended the group call'
  end;

  insert into public.messages (
    conversation_id,
    sender_id,
    sender_name,
    body,
    message_type,
    group_call_session_id,
    call_event,
    created_at
  ) values (
    new.conversation_id,
    actor_id,
    actor_name,
    event_body,
    'call',
    new.id,
    case when new.status = 'failed' then 'failed' else 'ended' end,
    coalesce(new.ended_at, now())
  );
  return new;
end;
$$;

drop trigger if exists on_group_call_finished_message on public.group_call_sessions;
create trigger on_group_call_finished_message
  after update of status on public.group_call_sessions
  for each row execute function public.log_group_call_finished_message();

revoke all on function public.start_group_call(uuid, boolean) from public, anon;
revoke all on function public.join_group_call(uuid) from public, anon;
revoke all on function public.decline_group_call(uuid) from public, anon;
revoke all on function public.leave_group_call(uuid) from public, anon;
revoke all on function public.fail_group_call(uuid, text) from public, anon;
revoke all on function public.apply_group_call_participant_event(uuid, uuid, text, timestamptz) from public, anon, authenticated;
revoke all on function public.apply_group_call_room_finished(uuid, text) from public, anon, authenticated;
grant execute on function public.start_group_call(uuid, boolean) to authenticated;
grant execute on function public.join_group_call(uuid) to authenticated;
grant execute on function public.decline_group_call(uuid) to authenticated;
grant execute on function public.leave_group_call(uuid) to authenticated;
grant execute on function public.fail_group_call(uuid, text) to authenticated;
grant execute on function public.apply_group_call_participant_event(uuid, uuid, text, timestamptz) to service_role;
grant execute on function public.apply_group_call_room_finished(uuid, text) to service_role;

create or replace function public.claim_group_call_control_jobs(
  batch_size integer default 25
)
returns table (
  id uuid,
  call_id uuid,
  user_id uuid,
  action text,
  attempts integer
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  with claimed as (
    select jobs.id
    from public.group_call_control_jobs as jobs
    where (
      jobs.status in ('pending', 'retry')
      and jobs.next_attempt_at <= now()
    ) or (
      jobs.status = 'sending'
      and jobs.updated_at <= now() - interval '2 minutes'
    )
    order by jobs.created_at
    limit least(greatest(coalesce(batch_size, 25), 1), 100)
    for update skip locked
  ), updated as (
    update public.group_call_control_jobs as jobs
    set status = 'sending', attempts = jobs.attempts + 1, updated_at = now()
    from claimed
    where jobs.id = claimed.id
    returning jobs.id, jobs.call_id, jobs.user_id, jobs.action, jobs.attempts
  )
  select updated.id, updated.call_id, updated.user_id, updated.action,
    updated.attempts
  from updated;
end;
$$;

create or replace function public.finish_group_call_control_job(
  target_job_id uuid,
  succeeded boolean,
  failure_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.group_call_control_jobs
  set status = case
        when succeeded then 'done'
        when attempts >= 8 then 'failed'
        else 'retry'
      end,
      next_attempt_at = case
        when succeeded or attempts >= 8 then next_attempt_at
        else now() + interval '30 seconds'
      end,
      last_error = case when succeeded then null else left(failure_reason, 500) end,
      updated_at = now()
  where id = target_job_id;
end;
$$;

revoke all on function public.claim_group_call_control_jobs(integer)
  from public, anon, authenticated;
revoke all on function public.finish_group_call_control_job(uuid, boolean, text)
  from public, anon, authenticated;
grant execute on function public.claim_group_call_control_jobs(integer) to service_role;
grant execute on function public.finish_group_call_control_job(uuid, boolean, text)
  to service_role;

do $$
begin
  if exists (
    select 1 from pg_publication where pubname = 'supabase_realtime'
  ) then
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'group_call_sessions'
    ) then
      alter publication supabase_realtime add table public.group_call_sessions;
    end if;
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'group_call_participants'
    ) then
      alter publication supabase_realtime add table public.group_call_participants;
    end if;
  end if;
end $$;

notify pgrst, 'reload schema';

alter table public.push_notification_jobs
  add column if not exists expires_at timestamptz;

create or replace function public.enqueue_push_notification_after_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  notification_preview text;
  notification_title text;
  notification_body text;
  notification_data jsonb;
  notification_expires_at timestamptz;
  conversation_record public.conversations;
  group_call_record public.group_call_sessions;
begin
  select * into conversation_record
  from public.conversations
  where id = new.conversation_id;

  notification_preview := public.push_message_preview(
    coalesce(new.message_type, 'text'), new.body
  );
  notification_title := case
    when conversation_record.conversation_type = 'group'
      then coalesce(conversation_record.title, 'Group')
    else new.sender_name
  end;
  notification_body := case
    when conversation_record.conversation_type = 'group'
      then new.sender_name || ': ' || notification_preview
    else notification_preview
  end;
  notification_data := jsonb_build_object(
    'type', 'message',
    'message_id', new.id,
    'conversation_id', new.conversation_id,
    'sender_id', new.sender_id,
    'chat_message_type', coalesce(new.message_type, 'text'),
    'conversation_type', conversation_record.conversation_type
  );

  if new.group_call_session_id is not null and new.call_event = 'started' then
    select * into group_call_record
    from public.group_call_sessions
    where id = new.group_call_session_id;
    notification_title := coalesce(group_call_record.title, notification_title);
    notification_body := new.sender_name || ' started a ' ||
      case when coalesce(group_call_record.is_video, false)
        then 'video call' else 'voice call' end;
    notification_expires_at := now() + interval '5 minutes';
    notification_data := notification_data || jsonb_build_object(
      'type', 'group_call',
      'call_id', new.group_call_session_id,
      'is_video', coalesce(group_call_record.is_video, false),
      'expires_at', notification_expires_at
    );
  end if;

  insert into public.push_notification_jobs (
    message_id, conversation_id, recipient_id, sender_id,
    title, body, data, expires_at
  )
  select
    new.id,
    new.conversation_id,
    members.user_id,
    new.sender_id,
    notification_title,
    notification_body,
    notification_data,
    notification_expires_at
  from public.conversation_members as members
  where members.conversation_id = new.conversation_id
    and members.user_id <> new.sender_id
    and members.left_at is null
    and members.joined_at <= new.created_at
  on conflict on constraint push_notification_jobs_message_recipient_key
    do nothing;

  perform public.invoke_push_notification_dispatch();
  return new;
end;
$$;

create or replace function public.drop_expired_group_call_notifications()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.push_notification_deliveries as deliveries
  set status = 'dropped', updated_at = now(), last_error = 'expired'
  from public.push_notification_jobs as jobs
  where jobs.id = deliveries.job_id
    and jobs.expires_at <= now()
    and deliveries.status in ('pending', 'retry', 'sending');

  update public.push_notification_jobs
  set status = 'dropped', updated_at = now(), last_error = 'expired'
  where expires_at <= now()
    and status in ('pending', 'retry', 'sending');
end;
$$;

revoke all on function public.drop_expired_group_call_notifications()
  from public, anon, authenticated;
grant execute on function public.drop_expired_group_call_notifications()
  to service_role;

notify pgrst, 'reload schema';
