-- Run with `supabase test db` after applying all migrations.
begin;

do $$
declare
  sender_id uuid := '11000000-0000-0000-0000-000000000001';
  recipient_id uuid := '11000000-0000-0000-0000-000000000002';
  outsider_id uuid := '11000000-0000-0000-0000-000000000003';
  conversation_id uuid := '22000000-0000-0000-0000-000000000001';
  other_conversation_id uuid := '22000000-0000-0000-0000-000000000002';
  source_message_id uuid := '33000000-0000-0000-0000-000000000001';
  reply_message_id uuid := '33000000-0000-0000-0000-000000000002';
  other_message_id uuid := '33000000-0000-0000-0000-000000000003';
  reaction_added boolean;
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  ) values
    (sender_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'actions-sender@example.test', 'not-used', now(), '{}', '{}', now(), now()),
    (recipient_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'actions-recipient@example.test', 'not-used', now(), '{}', '{}', now(), now()),
    (outsider_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'actions-outsider@example.test', 'not-used', now(), '{}', '{}', now(), now());

  insert into public.conversations (id, user_one_id, user_two_id) values
    (conversation_id, sender_id, recipient_id),
    (other_conversation_id, sender_id, outsider_id);

  insert into public.messages (
    id, conversation_id, sender_id, sender_name, body
  ) values
    (source_message_id, conversation_id, sender_id, 'Sender', 'Original'),
    (other_message_id, other_conversation_id, sender_id, 'Sender', 'Other');

  insert into public.messages (
    id, conversation_id, sender_id, sender_name, body, reply_to_message_id
  ) values (
    reply_message_id, conversation_id, recipient_id, 'Recipient', 'Reply',
    source_message_id
  );

  begin
    insert into public.messages (
      conversation_id, sender_id, sender_name, body, reply_to_message_id
    ) values (
      conversation_id, recipient_id, 'Recipient', 'Invalid reply',
      other_message_id
    );
    raise exception 'Cross-conversation reply was accepted';
  exception
    when others then
      if sqlerrm = 'Cross-conversation reply was accepted' then raise; end if;
  end;

  perform set_config('request.jwt.claim.sub', outsider_id::text, true);
  begin
    perform public.toggle_message_reaction(source_message_id, '👍');
    raise exception 'Non-member reaction was accepted';
  exception
    when others then
      if sqlerrm = 'Non-member reaction was accepted' then raise; end if;
  end;

  perform set_config('request.jwt.claim.sub', recipient_id::text, true);
  select public.toggle_message_reaction(source_message_id, '👍')
  into reaction_added;
  if not reaction_added then raise exception 'Reaction was not added'; end if;
  if (
    select count(*) from public.message_reactions
    where message_id = source_message_id and user_id = recipient_id
  ) <> 1 then
    raise exception 'Reaction uniqueness was not preserved';
  end if;
  select public.toggle_message_reaction(source_message_id, '👍')
  into reaction_added;
  if reaction_added or exists (
    select 1 from public.message_reactions
    where message_id = source_message_id and user_id = recipient_id
  ) then
    raise exception 'Reaction toggle did not remove the existing reaction';
  end if;
  perform public.toggle_message_reaction(source_message_id, '👍');

  begin
    perform public.edit_message(source_message_id, 'Unauthorized edit');
    raise exception 'Another user edited the message';
  exception
    when others then
      if sqlerrm = 'Another user edited the message' then raise; end if;
  end;

  begin
    perform * from public.delete_message(source_message_id);
    raise exception 'Another user deleted the message';
  exception
    when others then
      if sqlerrm = 'Another user deleted the message' then raise; end if;
  end;

  perform set_config('request.jwt.claim.sub', sender_id::text, true);
  perform public.edit_message(source_message_id, 'Edited body');
  if not exists (
    select 1 from public.messages
    where id = source_message_id and body = 'Edited body' and edited_at is not null
  ) then
    raise exception 'Authorized edit was not persisted';
  end if;

  perform * from public.delete_message(source_message_id);
  if not exists (
    select 1 from public.messages
    where id = source_message_id and deleted_at is not null and body = ''
      and media_path is null
  ) then
    raise exception 'Delete did not preserve a clean tombstone';
  end if;
  if exists (
    select 1 from public.message_reactions where message_id = source_message_id
  ) then
    raise exception 'Delete did not clear reactions';
  end if;
end;
$$;

rollback;
