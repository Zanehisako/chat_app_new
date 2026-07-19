-- Run with Supabase DB tests after applying all migrations.
begin;

do $$
declare
  first_user_id uuid := '81000000-0000-0000-0000-000000000001';
  second_user_id uuid := '81000000-0000-0000-0000-000000000002';
  third_user_id uuid := '81000000-0000-0000-0000-000000000003';
  fourth_user_id uuid := '81000000-0000-0000-0000-000000000004';
  direct_conversation_id uuid := '82000000-0000-0000-0000-000000000001';
  group_conversation_id uuid := '82000000-0000-0000-0000-000000000002';
  first_device_id uuid := '83000000-0000-0000-0000-000000000001';
  second_device_id uuid := '83000000-0000-0000-0000-000000000002';
  replacement_first_device_id uuid := '83000000-0000-0000-0000-000000000003';
  first_epoch_id uuid := '84000000-0000-0000-0000-000000000001';
  second_epoch_id uuid := '84000000-0000-0000-0000-000000000002';
  encrypted_message_id uuid := '85000000-0000-0000-0000-000000000001';
  state_row public.conversation_crypto_state;
  encrypted_message public.messages;
  generic_job public.push_notification_jobs;
  state_version integer;
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  )
  values
    (first_user_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'e2ee-first@example.test', 'not-used', now(), '{}', '{}', now(), now()),
    (second_user_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'e2ee-second@example.test', 'not-used', now(), '{}', '{}', now(), now()),
    (third_user_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'e2ee-third@example.test', 'not-used', now(), '{}', '{}', now(), now()),
    (fourth_user_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
      'authenticated', 'e2ee-fourth@example.test', 'not-used', now(), '{}', '{}', now(), now());

  insert into public.conversations (
    id, user_one_id, user_two_id
  )
  values (direct_conversation_id, first_user_id, second_user_id);

  perform set_config('request.jwt.claim.sub', first_user_id::text, true);
  perform public.register_e2ee_account(
    repeat('a', 43), repeat('b', 43), 1
  );
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform public.register_verified_e2ee_device(
    first_user_id,
    first_device_id,
    repeat('c', 43),
    repeat('d', 43),
    repeat('e', 86),
    'First device',
    1
  );
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  perform set_config('request.jwt.claim.sub', second_user_id::text, true);
  perform public.register_e2ee_account(
    repeat('f', 43), repeat('g', 43), 1
  );
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform public.register_verified_e2ee_device(
    second_user_id,
    second_device_id,
    repeat('h', 43),
    repeat('i', 43),
    repeat('j', 86),
    'Second device',
    1
  );
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  perform set_config('request.jwt.claim.sub', first_user_id::text, true);
  if (
    select count(*)
    from public.get_conversation_e2ee_key_material(direct_conversation_id)
  ) <> 4 then
    raise exception 'Recipient key material did not include two recovery keys and two devices';
  end if;

  select * into state_row
  from public.conversation_crypto_state
  where conversation_id = direct_conversation_id;
  state_version := state_row.membership_version;

  perform *
  from public.publish_conversation_epoch(
    direct_conversation_id,
    first_epoch_id,
    1,
    state_version,
    first_device_id,
    repeat('k', 32),
    repeat('l', 86),
    jsonb_build_array(
      jsonb_build_object(
        'recipient_kind', 'recovery',
        'recipient_user_id', first_user_id,
        'recipient_device_id', null,
        'ciphertext', repeat('m', 80)
      ),
      jsonb_build_object(
        'recipient_kind', 'device',
        'recipient_user_id', first_user_id,
        'recipient_device_id', first_device_id,
        'ciphertext', repeat('n', 80)
      ),
      jsonb_build_object(
        'recipient_kind', 'recovery',
        'recipient_user_id', second_user_id,
        'recipient_device_id', null,
        'ciphertext', repeat('o', 80)
      ),
      jsonb_build_object(
        'recipient_kind', 'device',
        'recipient_user_id', second_user_id,
        'recipient_device_id', second_device_id,
        'ciphertext', repeat('p', 80)
      )
    )
  );

  select * into state_row
  from public.conversation_crypto_state
  where conversation_id = direct_conversation_id;
  if state_row.active_epoch_id <> first_epoch_id
    or state_row.active_epoch_number <> 1
    or state_row.rekey_required then
    raise exception 'Publishing an E2EE epoch did not activate the supplied client epoch id';
  end if;

  select * into encrypted_message
  from public.send_encrypted_message(
    direct_conversation_id,
    first_device_id,
    first_epoch_id,
    repeat('q', 96),
    repeat('r', 32),
    repeat('s', 86),
    'text',
    null,
    null,
    encrypted_message_id
  );

  if encrypted_message.body <> ''
    or encrypted_message.encryption_version <> 1
    or encrypted_message.e2ee_epoch_id <> first_epoch_id
    or encrypted_message.e2ee_revision <> 1
    or encrypted_message.sender_name <> ''
    or encrypted_message.reply_to_message_id is not null
    or encrypted_message.is_forwarded
    or encrypted_message.latest_revision_id is null then
    raise exception 'Encrypted message routing row retained plaintext or missed its revision';
  end if;
  if (
    select count(*) from public.message_revisions
    where message_id = encrypted_message_id
  ) <> 1 then
    raise exception 'Encrypted message did not write its immutable initial revision';
  end if;
  if not exists (
    select 1
    from public.get_conversation_summaries()
    where conversation_id = direct_conversation_id
      and latest_message_id = encrypted_message_id
      and latest_message_reply_to_message_id is null
      and latest_message_ciphertext = repeat('q', 96)
  ) then
    raise exception 'Conversation summaries omitted encrypted reply or ciphertext routing fields';
  end if;

  select * into generic_job
  from public.push_notification_jobs
  where message_id = encrypted_message_id
    and recipient_id = second_user_id;
  if generic_job.title <> 'New message'
    or generic_job.body <> 'Open ChatApp to read it'
    or generic_job.data ? 'ciphertext'
    or generic_job.data ? 'body'
    or generic_job.data ? 'chat_message_type' then
    raise exception 'Encrypted message push job contains non-generic content';
  end if;

  perform set_config('request.jwt.claim.sub', second_user_id::text, true);
  if not exists (
    select 1
    from public.get_e2ee_device_envelopes(second_device_id)
    where epoch_id = first_epoch_id
      and created_by_device_id = first_device_id
      and creator_device_signing_public_key = repeat('d', 43)
      and creator_device_certificate = repeat('e', 86)
      and creator_account_signing_public_key = repeat('b', 43)
  ) then
    raise exception 'Device envelope retrieval omitted historical epoch signer identity';
  end if;
  if not exists (
    select 1
    from public.get_conversation_e2ee_device_identities(
      direct_conversation_id,
      array[first_device_id]
    )
    where device_id = first_device_id
      and signing_public_key = repeat('d', 43)
      and account_signing_public_key = repeat('b', 43)
  ) then
    raise exception 'Historical device identity lookup did not return a verifiable sender';
  end if;

  perform set_config('request.jwt.claim.sub', first_user_id::text, true);
  perform public.edit_encrypted_message(
    encrypted_message_id,
    first_device_id,
    first_epoch_id,
    2,
    repeat('t', 96),
    repeat('u', 32),
    repeat('v', 86)
  );
  if not exists (
    select 1
    from public.messages
    where id = encrypted_message_id
      and e2ee_revision = 2
      and e2ee_ciphertext = repeat('t', 96)
      and edited_at is not null
  ) or (
    select count(*) from public.message_revisions
    where message_id = encrypted_message_id
  ) <> 2 then
    raise exception 'Encrypted edit did not append and expose the current revision';
  end if;
  begin
    perform public.edit_encrypted_message(
      encrypted_message_id,
      first_device_id,
      first_epoch_id,
      2,
      repeat('t', 96),
      repeat('u', 32),
      repeat('v', 86)
    );
    raise exception 'Stale encrypted edit revision was accepted';
  exception
    when others then
      if sqlerrm = 'Stale encrypted edit revision was accepted' then
        raise;
      end if;
  end;

  perform set_config('request.jwt.claim.sub', second_user_id::text, true);
  if not public.set_encrypted_reaction(
    encrypted_message_id,
    second_device_id,
    first_epoch_id,
    repeat('w', 32),
    true,
    repeat('x', 64),
    repeat('y', 32),
    repeat('z', 86)
  ) then
    raise exception 'Encrypted reaction was not added';
  end if;
  if not exists (
    select 1 from public.encrypted_message_reactions
    where message_id = encrypted_message_id
      and reaction_tag = repeat('w', 32)
      and ciphertext = repeat('x', 64)
  ) then
    raise exception 'Encrypted reaction row was not stored as opaque data';
  end if;
  if public.set_encrypted_reaction(
    encrypted_message_id,
    second_device_id,
    first_epoch_id,
    repeat('w', 32),
    false
  ) then
    raise exception 'Encrypted reaction removal reported an active reaction';
  end if;

  perform set_config('request.jwt.claim.sub', first_user_id::text, true);
  perform * from public.delete_message(encrypted_message_id);
  if not exists (
    select 1
    from public.messages
    where id = encrypted_message_id
      and deleted_at is not null
      and body = ''
      and e2ee_ciphertext is null
      and latest_revision_id is null
  ) or exists (
    select 1 from public.message_revisions
    where message_id = encrypted_message_id
  ) then
    raise exception 'Encrypted deletion left decryptable message revisions behind';
  end if;

  perform public.revoke_e2ee_device(first_device_id);
  if not (
    select rekey_required
    from public.conversation_crypto_state
    where conversation_id = direct_conversation_id
  ) then
    raise exception 'Device revocation did not freeze encrypted sends pending rekey';
  end if;
  begin
    perform *
    from public.send_encrypted_message(
      direct_conversation_id,
      first_device_id,
      first_epoch_id,
      repeat('q', 96),
      repeat('r', 32),
      repeat('s', 86),
      'text'
    );
    raise exception 'Revoked-device encrypted send was accepted';
  exception
    when others then
      if sqlerrm = 'Revoked-device encrypted send was accepted' then
        raise;
      end if;
  end;

  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform public.register_verified_e2ee_device(
    first_user_id,
    replacement_first_device_id,
    repeat('A', 43),
    repeat('B', 43),
    repeat('C', 86),
    'Replacement first device',
    1
  );
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  select membership_version into state_version
  from public.conversation_crypto_state
  where conversation_id = direct_conversation_id;

  perform set_config('request.jwt.claim.sub', second_user_id::text, true);
  perform *
  from public.publish_conversation_epoch(
    direct_conversation_id,
    second_epoch_id,
    2,
    state_version,
    second_device_id,
    repeat('D', 32),
    repeat('E', 86),
    jsonb_build_array(
      jsonb_build_object(
        'recipient_kind', 'recovery',
        'recipient_user_id', first_user_id,
        'recipient_device_id', null,
        'ciphertext', repeat('F', 80)
      ),
      jsonb_build_object(
        'recipient_kind', 'device',
        'recipient_user_id', first_user_id,
        'recipient_device_id', replacement_first_device_id,
        'ciphertext', repeat('G', 80)
      ),
      jsonb_build_object(
        'recipient_kind', 'recovery',
        'recipient_user_id', second_user_id,
        'recipient_device_id', null,
        'ciphertext', repeat('H', 80)
      ),
      jsonb_build_object(
        'recipient_kind', 'device',
        'recipient_user_id', second_user_id,
        'recipient_device_id', second_device_id,
        'ciphertext', repeat('I', 80)
      )
    )
  );
  if (
    select active_epoch_id
    from public.conversation_crypto_state
    where conversation_id = direct_conversation_id
  ) <> second_epoch_id then
    raise exception 'Replacement device epoch did not become active';
  end if;

  if not exists (
    select 1
    from public.e2ee_rollout_config
    where id = true and plaintext_cutover_at is not null
  ) then
    raise exception 'E2EE rollout did not disable new plaintext messages';
  end if;
  perform set_config('request.jwt.claim.sub', first_user_id::text, true);
  begin
    insert into public.messages (
      conversation_id, sender_id, sender_name, body, message_type
    )
    values (
      direct_conversation_id, first_user_id, 'First', 'plaintext must fail', 'text'
    );
    raise exception 'Plaintext write was accepted after E2EE cutover';
  exception
    when others then
      if sqlerrm = 'Plaintext write was accepted after E2EE cutover' then
        raise;
      end if;
  end;

  if exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'messages'
      and cmd in ('INSERT', 'ALL')
  ) then
    raise exception 'Direct message insertion remains available after E2EE cutover';
  end if;
  if has_function_privilege(
    'authenticated',
    'public.register_e2ee_device(uuid, text, text, text, text, integer)',
    'EXECUTE'
  ) then
    raise exception 'Authenticated clients can bypass verified device registration';
  end if;

  insert into public.conversations (
    id, conversation_type, title, created_by
  )
  values (
    group_conversation_id, 'group', 'E2EE group', first_user_id
  );
  insert into public.conversation_members (
    conversation_id, user_id, role
  )
  values
    (group_conversation_id, first_user_id, 'admin'),
    (group_conversation_id, second_user_id, 'member'),
    (group_conversation_id, third_user_id, 'member');
  select membership_version into state_version
  from public.conversation_crypto_state
  where conversation_id = group_conversation_id;
  insert into public.conversation_members (
    conversation_id, user_id, role
  )
  values (group_conversation_id, fourth_user_id, 'member');
  if not (
    select rekey_required
      and membership_version = state_version + 1
    from public.conversation_crypto_state
    where conversation_id = group_conversation_id
  ) then
    raise exception 'Group membership changes did not require a new E2EE epoch';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'message_revisions'
      and policyname = 'Conversation members can read encrypted revisions'
  ) then
    raise exception 'Encrypted revision RLS policy is missing';
  end if;
  if exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'conversation_key_envelopes'
  ) then
    raise exception 'Key envelopes must be retrieved only through scoped RPCs';
  end if;
end;
$$;

rollback;
