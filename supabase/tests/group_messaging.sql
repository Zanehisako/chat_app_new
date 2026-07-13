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
