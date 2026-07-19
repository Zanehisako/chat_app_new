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

  -- These rows represent history from before the irreversible E2EE cutover.
  update public.e2ee_rollout_config
  set plaintext_cutover_at = null
  where id = true;
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
  update public.e2ee_rollout_config
  set plaintext_cutover_at = now()
  where id = true;

  perform set_config('request.jwt.claim.sub', outsider_id::text, true);
  begin
    perform public.toggle_message_reaction(source_message_id, '👍');
    raise exception 'Non-member reaction was accepted';
  exception
    when others then
      if sqlerrm = 'Non-member reaction was accepted' then raise; end if;
  end;

  perform set_config('request.jwt.claim.sub', recipient_id::text, true);
  begin
    perform public.toggle_message_reaction(source_message_id, '👍');
    raise exception 'Legacy reaction was accepted after E2EE cutover';
  exception
    when others then
      if sqlerrm = 'Legacy reaction was accepted after E2EE cutover' then raise; end if;
  end;

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
  begin
    perform public.edit_message(source_message_id, 'Edited body');
    raise exception 'Legacy edit was accepted after E2EE cutover';
  exception
    when others then
      if sqlerrm = 'Legacy edit was accepted after E2EE cutover' then raise; end if;
  end;
  begin
    perform * from public.delete_message(source_message_id);
    raise exception 'Legacy delete was accepted after E2EE cutover';
  exception
    when others then
      if sqlerrm = 'Legacy delete was accepted after E2EE cutover' then raise; end if;
  end;
  if not exists (
    select 1
    from public.messages
    where id = source_message_id
      and body = 'Original'
      and deleted_at is null
  ) then
    raise exception 'A historical message changed after a rejected legacy action';
  end if;
end;
$$;

rollback;
