-- Run with `supabase test db` after the push migrations are applied.
begin;

do $$
declare
  preview text;
begin
  select public.push_message_preview('image', '') into preview;
  if preview <> 'Sent a photo' then
    raise exception 'Unexpected media notification preview: %', preview;
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'push_device_tokens'
      and column_name = 'expires_at'
  ) then
    raise exception 'Missing token expiry column';
  end if;

  if not exists (
    select 1 from pg_class
    where relnamespace = 'public'::regnamespace
      and relname = 'push_notification_deliveries'
  ) then
    raise exception 'Missing per-device delivery table';
  end if;

  if exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'push_device_tokens'
      and cmd in ('ALL', 'INSERT', 'UPDATE', 'DELETE')
  ) then
    raise exception 'Push token mutations must use security-definer RPCs';
  end if;

  if (
    select count(distinct proname)
    from pg_proc
    where pronamespace = 'public'::regnamespace
      and proname in (
        'register_push_device_token',
        'unregister_push_device_token',
        'claim_push_notification_deliveries',
        'refresh_push_notification_job'
      )
  ) <> 4 then
    raise exception 'Missing a required push notification RPC';
  end if;

  -- Compile and execute the set-returning claim body even when no jobs exist.
  -- This catches PL/pgSQL output-column ambiguity that catalog checks miss.
  perform * from public.claim_push_notification_deliveries(1);

  if not exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.push_notification_jobs'::regclass
      and tgname = 'on_push_notification_job_snapshot_deliveries'
      and not tgisinternal
  ) then
    raise exception 'Missing job-to-delivery snapshot trigger';
  end if;

  if exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename in ('push_notification_jobs', 'push_notification_dispatch_config')
  ) then
    raise exception 'Push jobs and dispatcher configuration must not be app-readable';
  end if;
end;
$$;

do $$
declare
  first_user uuid := '10000000-0000-0000-0000-000000000001';
  second_user uuid := '10000000-0000-0000-0000-000000000002';
  claimed_token_id uuid;
  token_owner uuid;
  conversation_id uuid := '20000000-0000-0000-0000-000000000001';
  message_id uuid := '30000000-0000-0000-0000-000000000001';
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  )
  values
    (
      first_user, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'push-first@example.test', 'not-used', now(), '{}', '{}', now(), now()
    ),
    (
      second_user, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'push-second@example.test', 'not-used', now(), '{}', '{}', now(), now()
    );

  perform set_config('request.jwt.claim.sub', first_user::text, true);
  select public.register_push_device_token(
    'fcm', 'shared-test-token', 'android', null, null
  ) into claimed_token_id;
  if claimed_token_id is null then
    raise exception 'Token registration did not return an id';
  end if;

  perform set_config('request.jwt.claim.sub', second_user::text, true);
  perform public.register_push_device_token(
    'fcm', 'shared-test-token', 'ios', null, null
  );

  perform public.register_push_device_token(
    'wns', 'https://example.notify.windows.com/channel', 'windows', null, null
  );
  begin
    perform public.register_push_device_token(
      'wns', 'http://example.notify.windows.com/channel', 'windows', null, null
    );
    raise exception 'An insecure WNS URI was accepted';
  exception
    when others then
      if sqlerrm <> 'Invalid WNS channel URI' then
        raise;
      end if;
  end;

  select user_id into token_owner
  from public.push_device_tokens
  where id = claimed_token_id;
  if token_owner <> second_user then
    raise exception 'Token registration did not transfer ownership to the active account';
  end if;

  insert into public.conversations (id, user_one_id, user_two_id)
  values (conversation_id, first_user, second_user);

  insert into public.messages (
    id, conversation_id, sender_id, sender_name, body
  )
  values (
    message_id, conversation_id, first_user, 'Push First', 'Trigger test'
  );

  if not exists (
    select 1
    from public.push_notification_jobs as jobs
    where jobs.message_id = message_id
      and jobs.recipient_id = second_user
      and jobs.sender_id = first_user
  ) then
    raise exception 'Message trigger did not enqueue the recipient push job';
  end if;
end;
$$;

rollback;
