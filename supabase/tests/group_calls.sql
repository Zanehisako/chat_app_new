-- Run with `supabase test db` after applying all migrations.
begin;

do $$
declare
  admin_id uuid := '51000000-0000-0000-0000-000000000001';
  member_id uuid := '51000000-0000-0000-0000-000000000002';
  outsider_id uuid := '51000000-0000-0000-0000-000000000003';
  conversation_id uuid;
  group_row public.conversations;
  call_row public.group_call_sessions;
  join_failed boolean;
begin
  if not exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and indexname = 'group_call_sessions_one_active_idx'
  ) then
    raise exception 'Missing one-active-group-call invariant';
  end if;
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'group_call_participants'
      and policyname = 'Active members can read group call participants'
  ) then
    raise exception 'Missing group call participant RLS';
  end if;

  if not exists (
    select 1
    from pg_class
    join pg_namespace on pg_namespace.oid = pg_class.relnamespace
    where pg_namespace.nspname = 'public'
      and pg_class.relname = 'group_call_control_dispatch_config'
      and pg_class.relrowsecurity
  ) then
    raise exception 'Missing protected group call control dispatch config';
  end if;
  if not exists (
    select 1
    from pg_trigger
    join pg_class on pg_class.oid = pg_trigger.tgrelid
    join pg_namespace on pg_namespace.oid = pg_class.relnamespace
    where pg_namespace.nspname = 'public'
      and pg_class.relname = 'group_call_control_jobs'
      and pg_trigger.tgname = 'on_group_call_control_job_insert'
      and not pg_trigger.tgisinternal
  ) then
    raise exception 'Missing immediate group call control dispatch trigger';
  end if;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values
    (admin_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'group-call-admin@example.test', 'not-used', now(), '{}', '{}', now(), now()),
    (member_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'group-call-member@example.test', 'not-used', now(), '{}', '{}', now(), now()),
    (outsider_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'group-call-outsider@example.test', 'not-used', now(), '{}', '{}', now(), now());

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  select * into group_row
  from public.create_group_conversation('Group calls', array[member_id]);
  conversation_id := group_row.id;
  select * into call_row from public.start_group_call(conversation_id, true);

  if call_row.status <> 'active' or call_row.is_video is not true then
    raise exception 'Group call did not start';
  end if;
  if (select count(*) from public.group_call_participants where call_id = call_row.id) <> 2 then
    raise exception 'Group call did not snapshot active members';
  end if;
  if (select count(*) from public.messages where group_call_session_id = call_row.id and call_event = 'started') <> 1 then
    raise exception 'Group call start history was not written exactly once';
  end if;

  perform set_config('request.jwt.claim.sub', outsider_id::text, true);
  join_failed := false;
  begin
    perform public.join_group_call(call_row.id);
  exception when others then
    join_failed := true;
  end;
  if not join_failed then
    raise exception 'Outsider joined a group call';
  end if;

  perform set_config('request.jwt.claim.sub', member_id::text, true);
  perform public.join_group_call(call_row.id);
  perform public.leave_group_call(call_row.id);
  if (select status from public.group_call_sessions where id = call_row.id) <> 'active' then
    raise exception 'One participant leaving ended the room';
  end if;

  -- A connected member removal must enqueue exactly one Cloud control job.
  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform public.add_group_member(conversation_id, outsider_id);
  perform set_config('request.jwt.claim.sub', outsider_id::text, true);
  perform public.join_group_call(call_row.id);
  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform public.remove_group_member(conversation_id, outsider_id);
  if (select status from public.group_call_participants
      where call_id = call_row.id and user_id = outsider_id) <> 'removed' then
    raise exception 'Connected removed member was not invalidated';
  end if;
  if (select count(*) from public.group_call_control_jobs
      where call_id = call_row.id and user_id = outsider_id
        and action = 'remove') <> 1 then
    raise exception 'Connected removed member did not enqueue one control job';
  end if;

  -- Removing a member invalidates their current-call entry even if they had
  -- already left. Re-adding them must not let them resurrect the same call.
  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform public.remove_group_member(conversation_id, member_id);
  if (select status from public.group_call_participants
      where call_id = call_row.id and user_id = member_id) <> 'removed' then
    raise exception 'Removed member was not invalidated for the active call';
  end if;
  perform public.add_group_member(conversation_id, member_id);
  perform set_config('request.jwt.claim.sub', member_id::text, true);
  join_failed := false;
  begin
    perform public.join_group_call(call_row.id);
  exception when others then
    join_failed := true;
  end;
  if not join_failed then
    raise exception 'Re-added member resurrected a removed call entry';
  end if;

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform public.leave_group_call(call_row.id);
  if (select status from public.group_call_sessions where id = call_row.id) <> 'ended' then
    raise exception 'Last participant leaving did not end the room';
  end if;
  if (select count(*) from public.messages where group_call_session_id = call_row.id and call_event = 'ended') <> 1 then
    raise exception 'Group call end history was not written exactly once';
  end if;
end;
$$;

rollback;
