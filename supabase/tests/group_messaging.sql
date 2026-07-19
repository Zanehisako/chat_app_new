-- Run with `supabase test db` after applying all migrations.
begin;

do $$
declare
  admin_id uuid := '41000000-0000-0000-0000-000000000001';
  first_member_id uuid := '41000000-0000-0000-0000-000000000002';
  second_member_id uuid := '41000000-0000-0000-0000-000000000003';
  added_member_id uuid := '41000000-0000-0000-0000-000000000004';
  outsider_id uuid := '41000000-0000-0000-0000-000000000005';
  direct_id uuid := '42000000-0000-0000-0000-000000000001';
  group_row public.conversations;
  first_message_id uuid := '43000000-0000-0000-0000-000000000001';
  second_message_id uuid := '43000000-0000-0000-0000-000000000002';
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values
    (admin_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'group-admin@example.test', 'not-used', now(), '{}', '{}', now(), now()),
    (first_member_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'group-first@example.test', 'not-used', now(), '{}', '{}', now(), now()),
    (second_member_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'group-second@example.test', 'not-used', now(), '{}', '{}', now(), now()),
    (added_member_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'group-added@example.test', 'not-used', now(), '{}', '{}', now(), now()),
    (outsider_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'group-outsider@example.test', 'not-used', now(), '{}', '{}', now(), now());

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  select * into group_row
  from public.create_group_conversation(
    'Launch Team', array[first_member_id, second_member_id]
  );

  if group_row.conversation_type <> 'group'
    or group_row.title <> 'Launch Team'
    or group_row.created_by <> admin_id then
    raise exception 'Group metadata was not created correctly';
  end if;
  if (
    select count(*) from public.conversation_members
    where conversation_id = group_row.id and left_at is null
  ) <> 3 then
    raise exception 'Group members were not created atomically';
  end if;
  if not public.is_group_admin(group_row.id, admin_id) then
    raise exception 'Creator was not made group admin';
  end if;

  -- Historical fixtures are created under the pre-cutover state. New-message
  -- behavior is exercised by the encrypted-message test instead.
  update public.e2ee_rollout_config
  set plaintext_cutover_at = null
  where id = true;
  insert into public.messages (
    id, conversation_id, sender_id, sender_name, body, created_at
  ) values (
    first_message_id, group_row.id, admin_id, 'Admin', 'Before join',
    now() - interval '1 minute'
  );
  if (
    select count(*) from public.message_receipts
    where message_id = first_message_id
  ) <> 2 then
    raise exception 'Initial group receipt fan-out was incorrect';
  end if;
  if (
    select count(*) from public.push_notification_jobs
    where message_id = first_message_id
  ) <> 2 then
    raise exception 'Initial group notification fan-out was incorrect';
  end if;

  perform public.add_group_member(group_row.id, added_member_id);
  if public.is_conversation_member(
    group_row.id,
    added_member_id,
    now() - interval '1 minute'
  ) then
    raise exception 'A newly added member can access pre-join history';
  end if;

  insert into public.messages (
    id, conversation_id, sender_id, sender_name, body, created_at
  ) values (
    second_message_id, group_row.id, admin_id, 'Admin', 'After join', now()
  );
  update public.e2ee_rollout_config
  set plaintext_cutover_at = now()
  where id = true;
  if (
    select count(*) from public.message_receipts
    where message_id = second_message_id
  ) <> 3 then
    raise exception 'Added member did not receive a message receipt';
  end if;
  if (
    select count(*) from public.push_notification_jobs
    where message_id = second_message_id
  ) <> 3 then
    raise exception 'Added member did not receive a notification job';
  end if;

  perform set_config('request.jwt.claim.sub', first_member_id::text, true);
  begin
    perform public.rename_group_conversation(group_row.id, 'Unauthorized');
    raise exception 'A non-admin renamed the group';
  exception
    when others then
      if sqlerrm = 'A non-admin renamed the group' then raise; end if;
  end;

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  perform public.rename_group_conversation(group_row.id, 'Release Team');
  perform public.remove_group_member(group_row.id, first_member_id);
  if public.is_conversation_member(group_row.id, first_member_id) then
    raise exception 'Removed member retained active access';
  end if;
  perform public.add_group_member(group_row.id, first_member_id);
  if public.is_conversation_member(
    group_row.id,
    first_member_id,
    (select created_at from public.messages where id = first_message_id)
  ) then
    raise exception 'Re-added member regained old message history';
  end if;

  perform public.leave_group_conversation(group_row.id);
  if public.is_conversation_member(group_row.id, admin_id) then
    raise exception 'Leaving admin retained active access';
  end if;
  if not exists (
    select 1 from public.conversation_members
    where conversation_id = group_row.id
      and role = 'admin'
      and left_at is null
  ) then
    raise exception 'Leaving last admin did not promote another member';
  end if;

  insert into public.conversations (id, user_one_id, user_two_id)
  values (direct_id, admin_id, outsider_id);
  if (
    select count(*) from public.conversation_members
    where conversation_id = direct_id and left_at is null
  ) <> 2 then
    raise exception 'Direct conversation membership backfill trigger failed';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'messages'
      and policyname = 'Users can read own conversation messages'
      and qual like '%is_conversation_member%'
  ) then
    raise exception 'Message RLS is not membership-based';
  end if;
end;
$$;

rollback;

begin;

do $$
declare
  sender_id uuid := '51000000-0000-0000-0000-000000000001';
  recipient_id uuid := '51000000-0000-0000-0000-000000000002';
  group_member_id uuid := '51000000-0000-0000-0000-000000000003';
  joined_later_id uuid := '51000000-0000-0000-0000-000000000004';
  outsider_id uuid := '51000000-0000-0000-0000-000000000005';
  direct_id uuid := '52000000-0000-0000-0000-000000000001';
  empty_direct_id uuid := '52000000-0000-0000-0000-000000000002';
  group_id uuid := '52000000-0000-0000-0000-000000000003';
  direct_message_id uuid := '53000000-0000-0000-0000-000000000001';
  before_join_message_id uuid := '53000000-0000-0000-0000-000000000002';
  after_join_message_id uuid := '53000000-0000-0000-0000-000000000003';
  base_time timestamptz := now() - interval '1 hour';
  summary record;
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values
    (sender_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'summary-sender@example.test', 'not-used', now(), '{}', '{}', now(), now()),
    (recipient_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'summary-recipient@example.test', 'not-used', now(), '{}', '{}', now(), now()),
    (group_member_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'summary-group-member@example.test', 'not-used', now(), '{}', '{}', now(), now()),
    (joined_later_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'summary-joined-later@example.test', 'not-used', now(), '{}', '{}', now(), now()),
    (outsider_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'summary-outsider@example.test', 'not-used', now(), '{}', '{}', now(), now());

  insert into public.conversations (
    id, user_one_id, user_two_id, created_at, updated_at
  ) values
    (direct_id, sender_id, recipient_id, base_time, base_time),
    (empty_direct_id, sender_id, outsider_id, base_time, base_time);

  -- These rows represent messages written before E2EE v1 became mandatory.
  update public.e2ee_rollout_config
  set plaintext_cutover_at = null
  where id = true;
  insert into public.messages (
    id, conversation_id, sender_id, sender_name, body, created_at
  ) values (
    direct_message_id, direct_id, sender_id, 'Sender', 'Original direct message',
    base_time + interval '1 minute'
  );

  perform set_config('request.jwt.claim.sub', sender_id::text, true);
  select * into summary
  from public.get_conversation_summaries()
  where conversation_id = direct_id;
  if not found
    or summary.latest_message_id <> direct_message_id
    or summary.latest_message_body <> 'Original direct message'
    or summary.unread_count <> 0
    or summary.latest_outgoing_status <> 'sent'
    or summary.status <> 'sent' then
    raise exception 'Direct sent summary was incorrect';
  end if;

  select * into summary
  from public.get_conversation_summaries()
  where conversation_id = empty_direct_id;
  if not found
    or summary.latest_message_id is not null
    or summary.unread_count <> 0
    or summary.status <> 'none' then
    raise exception 'Empty conversation summary was incorrect';
  end if;

  perform set_config('request.jwt.claim.sub', recipient_id::text, true);
  select * into summary
  from public.get_conversation_summaries()
  where conversation_id = direct_id;
  if not found
    or summary.unread_count <> 1
    or summary.status <> 'unread'
    or summary.latest_outgoing_status is not null then
    raise exception 'Direct unread summary was incorrect';
  end if;

  update public.message_receipts
  set delivered_at = base_time + interval '2 minutes'
  where message_id = direct_message_id and user_id = recipient_id;

  perform set_config('request.jwt.claim.sub', sender_id::text, true);
  select * into summary
  from public.get_conversation_summaries()
  where conversation_id = direct_id;
  if summary.latest_outgoing_status <> 'delivered'
    or summary.status <> 'delivered' then
    raise exception 'Direct delivered summary was incorrect';
  end if;

  update public.message_receipts
  set read_at = base_time + interval '3 minutes'
  where message_id = direct_message_id and user_id = recipient_id;

  select * into summary
  from public.get_conversation_summaries()
  where conversation_id = direct_id;
  if summary.latest_outgoing_status <> 'read'
    or summary.status <> 'read' then
    raise exception 'Direct read summary was incorrect';
  end if;

  begin
    perform public.edit_message(direct_message_id, 'Edited direct message');
    raise exception 'Legacy edit was accepted after E2EE cutover';
  exception
    when others then
      if sqlerrm = 'Legacy edit was accepted after E2EE cutover' then raise; end if;
  end;
  begin
    perform * from public.delete_message(direct_message_id);
    raise exception 'Legacy delete was accepted after E2EE cutover';
  exception
    when others then
      if sqlerrm = 'Legacy delete was accepted after E2EE cutover' then raise; end if;
  end;
  select * into summary
  from public.get_conversation_summaries()
  where conversation_id = direct_id;
  if summary.latest_message_deleted_at is not null
    or summary.latest_message_body <> 'Original direct message'
    or summary.latest_message_type <> 'text' then
    raise exception 'Rejected legacy actions changed the direct summary';
  end if;

  insert into public.conversations (
    id, conversation_type, title, created_by, created_at, updated_at
  ) values (
    group_id, 'group', 'Summary Group', sender_id, base_time, base_time
  );
  insert into public.conversation_members (
    conversation_id, user_id, role, joined_at
  ) values
    (group_id, sender_id, 'admin', base_time),
    (group_id, group_member_id, 'member', base_time);

  insert into public.messages (
    id, conversation_id, sender_id, sender_name, body, created_at
  ) values (
    before_join_message_id, group_id, sender_id, 'Sender', 'Before join',
    base_time + interval '10 minutes'
  );
  insert into public.conversation_members (
    conversation_id, user_id, role, joined_at
  ) values (
    group_id, joined_later_id, 'member', base_time + interval '20 minutes'
  );

  perform set_config('request.jwt.claim.sub', joined_later_id::text, true);
  select * into summary
  from public.get_conversation_summaries()
  where conversation_id = group_id;
  if not found
    or summary.latest_message_id is not null
    or summary.unread_count <> 0
    or summary.status <> 'none' then
    raise exception 'Post-join visibility leaked an older group message';
  end if;
  if exists (
    select 1 from public.message_receipts
    where message_id = before_join_message_id and user_id = joined_later_id
  ) then
    raise exception 'A post-join member received a pre-join receipt';
  end if;

  insert into public.messages (
    id, conversation_id, sender_id, sender_name, body, created_at
  ) values (
    after_join_message_id, group_id, sender_id, 'Sender', 'After join',
    base_time + interval '30 minutes'
  );
  update public.e2ee_rollout_config
  set plaintext_cutover_at = now()
  where id = true;

  select * into summary
  from public.get_conversation_summaries()
  where conversation_id = group_id;
  if summary.latest_message_id <> after_join_message_id
    or summary.latest_message_body <> 'After join'
    or summary.unread_count <> 1
    or summary.status <> 'unread' then
    raise exception 'New group member summary was incorrect';
  end if;

  perform set_config('request.jwt.claim.sub', sender_id::text, true);
  select * into summary
  from public.get_conversation_summaries()
  where conversation_id = group_id;
  if summary.latest_outgoing_status <> 'sent'
    or summary.status <> 'sent' then
    raise exception 'Group sent summary did not require every recipient';
  end if;

  update public.message_receipts
  set delivered_at = base_time + interval '31 minutes'
  where message_id = after_join_message_id and user_id = group_member_id;
  select * into summary
  from public.get_conversation_summaries()
  where conversation_id = group_id;
  if summary.latest_outgoing_status <> 'sent' then
    raise exception 'Partial group delivery was marked delivered';
  end if;

  update public.message_receipts
  set delivered_at = base_time + interval '32 minutes'
  where message_id = after_join_message_id and user_id = joined_later_id;
  select * into summary
  from public.get_conversation_summaries()
  where conversation_id = group_id;
  if summary.latest_outgoing_status <> 'delivered'
    or summary.status <> 'delivered' then
    raise exception 'Complete group delivery summary was incorrect';
  end if;

  update public.message_receipts
  set read_at = base_time + interval '33 minutes'
  where message_id = after_join_message_id and user_id = group_member_id;
  select * into summary
  from public.get_conversation_summaries()
  where conversation_id = group_id;
  if summary.latest_outgoing_status <> 'delivered' then
    raise exception 'Partial group read was marked read';
  end if;

  update public.message_receipts
  set read_at = base_time + interval '34 minutes'
  where message_id = after_join_message_id and user_id = joined_later_id;
  select * into summary
  from public.get_conversation_summaries()
  where conversation_id = group_id;
  if summary.latest_outgoing_status <> 'read'
    or summary.status <> 'read' then
    raise exception 'Complete group read summary was incorrect';
  end if;

  perform set_config('request.jwt.claim.sub', outsider_id::text, true);
  if exists (
    select 1 from public.get_conversation_summaries()
    where conversation_id in (direct_id, group_id)
  ) then
    raise exception 'Conversation summary leaked to an outsider';
  end if;

  if exists (
    select 1 from pg_proc
    where oid = 'public.get_conversation_summaries()'::regprocedure
      and prosecdef
  ) then
    raise exception 'Conversation summary RPC must use security invoker';
  end if;
  if not has_function_privilege(
    'authenticated'::name,
    'public.get_conversation_summaries()'::regprocedure,
    'EXECUTE'
  ) then
    raise exception 'Authenticated users cannot execute the summary RPC';
  end if;
  if has_function_privilege(
    'anon'::name,
    'public.get_conversation_summaries()'::regprocedure,
    'EXECUTE'
  ) then
    raise exception 'Anonymous users can execute the summary RPC';
  end if;
end;
$$;

rollback;
