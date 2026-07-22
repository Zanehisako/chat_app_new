-- E2EE protocol v1.
--
-- The database stores only public identity material, encrypted key envelopes,
-- encrypted message/reaction envelopes, and the routing metadata required to
-- deliver a message. Private keys and plaintext content never enter Supabase.
-- Calls deliberately remain metadata-only in v1.

update storage.buckets
set file_size_limit = greatest(coalesce(file_size_limit, 0), 15728656),
    allowed_mime_types = array(
  select distinct mime_type
  from unnest(
    coalesce(allowed_mime_types, '{}'::text[])
    || array['application/octet-stream']::text[]
  ) as mime_type
)
where id = 'chat-media';

create table if not exists public.e2ee_accounts (
  user_id uuid primary key references auth.users (id) on delete cascade,
  protocol_version integer not null default 1 check (protocol_version = 1),
  recovery_public_key text not null,
  signing_public_key text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint e2ee_accounts_recovery_public_key_check
    check (char_length(recovery_public_key) between 40 and 512),
  constraint e2ee_accounts_signing_public_key_check
    check (char_length(signing_public_key) between 40 and 512)
);

create table if not exists public.e2ee_devices (
  id uuid primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  protocol_version integer not null default 1 check (protocol_version = 1),
  encryption_public_key text not null,
  signing_public_key text not null,
  certificate text not null,
  label text,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  revoked_at timestamptz,
  constraint e2ee_devices_encryption_public_key_check
    check (char_length(encryption_public_key) between 40 and 512),
  constraint e2ee_devices_signing_public_key_check
    check (char_length(signing_public_key) between 40 and 512),
  constraint e2ee_devices_certificate_check
    check (char_length(certificate) between 64 and 1024),
  constraint e2ee_devices_label_check
    check (label is null or char_length(label) between 1 and 120)
);

create unique index if not exists e2ee_devices_active_encryption_key_idx
  on public.e2ee_devices (user_id, encryption_public_key)
  where revoked_at is null;

create index if not exists e2ee_devices_active_user_idx
  on public.e2ee_devices (user_id, created_at)
  where revoked_at is null;

create table if not exists public.conversation_crypto_state (
  conversation_id uuid primary key
    references public.conversations (id) on delete cascade,
  protocol_version integer not null default 1 check (protocol_version = 1),
  membership_version integer not null default 0 check (membership_version >= 0),
  active_epoch_number integer,
  active_epoch_id uuid,
  rekey_required boolean not null default true,
  updated_at timestamptz not null default now(),
  constraint conversation_crypto_state_epoch_pair_check check (
    (active_epoch_number is null and active_epoch_id is null)
    or (
      active_epoch_number is not null
      and active_epoch_number > 0
      and active_epoch_id is not null
    )
  )
);

create table if not exists public.conversation_key_epochs (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null
    references public.conversations (id) on delete cascade,
  epoch_number integer not null check (epoch_number > 0),
  membership_version integer not null check (membership_version >= 0),
  created_by_user_id uuid not null references auth.users (id) on delete restrict,
  created_by_device_id uuid not null
    references public.e2ee_devices (id) on delete restrict,
  commitment text not null,
  signature text not null,
  created_at timestamptz not null default now(),
  constraint conversation_key_epochs_commitment_check
    check (char_length(commitment) between 16 and 4096),
  constraint conversation_key_epochs_signature_check
    check (char_length(signature) between 64 and 1024),
  constraint conversation_key_epochs_conversation_epoch_key
    unique (conversation_id, epoch_number)
);

create index if not exists conversation_key_epochs_conversation_created_idx
  on public.conversation_key_epochs (conversation_id, created_at desc);

alter table public.conversation_crypto_state
  drop constraint if exists conversation_crypto_state_active_epoch_fkey,
  add constraint conversation_crypto_state_active_epoch_fkey
  foreign key (active_epoch_id)
  references public.conversation_key_epochs (id)
  on delete restrict;

create table if not exists public.conversation_key_envelopes (
  id uuid primary key default gen_random_uuid(),
  epoch_id uuid not null
    references public.conversation_key_epochs (id) on delete cascade,
  conversation_id uuid not null
    references public.conversations (id) on delete cascade,
  recipient_kind text not null
    check (recipient_kind in ('device', 'recovery')),
  recipient_user_id uuid not null references auth.users (id) on delete cascade,
  recipient_device_id uuid references public.e2ee_devices (id) on delete cascade,
  ciphertext text not null,
  created_at timestamptz not null default now(),
  constraint conversation_key_envelopes_recipient_check check (
    (recipient_kind = 'device' and recipient_device_id is not null)
    or (recipient_kind = 'recovery' and recipient_device_id is null)
  ),
  constraint conversation_key_envelopes_ciphertext_check
    check (char_length(ciphertext) between 40 and 16384)
);

create unique index if not exists conversation_key_envelopes_device_key
  on public.conversation_key_envelopes (
    epoch_id, recipient_user_id, recipient_device_id
  )
  where recipient_kind = 'device';

create unique index if not exists conversation_key_envelopes_recovery_key
  on public.conversation_key_envelopes (epoch_id, recipient_user_id)
  where recipient_kind = 'recovery';

create index if not exists conversation_key_envelopes_recipient_device_idx
  on public.conversation_key_envelopes (recipient_device_id, created_at desc)
  where recipient_kind = 'device';

create index if not exists conversation_key_envelopes_recipient_recovery_idx
  on public.conversation_key_envelopes (recipient_user_id, created_at desc)
  where recipient_kind = 'recovery';

alter table public.messages
  add column if not exists encryption_version integer not null default 0,
  add column if not exists encryption_state text not null default 'legacy',
  add column if not exists e2ee_epoch_id uuid,
  add column if not exists e2ee_epoch_number integer,
  add column if not exists e2ee_sender_device_id uuid,
  add column if not exists e2ee_ciphertext text,
  add column if not exists e2ee_nonce text,
  add column if not exists e2ee_signature text,
  add column if not exists e2ee_aad_version smallint,
  add column if not exists e2ee_revision integer not null default 0,
  add column if not exists latest_revision_id uuid;

alter table public.messages
  drop constraint if exists messages_encryption_version_check,
  drop constraint if exists messages_encryption_state_check,
  add constraint messages_encryption_version_check
    check (encryption_version in (0, 1)),
  add constraint messages_encryption_state_check
    check (encryption_state in ('legacy', 'encrypted'));

alter table public.messages
  drop constraint if exists messages_e2ee_epoch_id_fkey,
  add constraint messages_e2ee_epoch_id_fkey
    foreign key (e2ee_epoch_id)
    references public.conversation_key_epochs (id)
    on delete restrict,
  drop constraint if exists messages_e2ee_sender_device_id_fkey,
  add constraint messages_e2ee_sender_device_id_fkey
    foreign key (e2ee_sender_device_id)
    references public.e2ee_devices (id)
    on delete restrict;

create table if not exists public.message_revisions (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.messages (id) on delete cascade,
  revision integer not null check (revision > 0),
  epoch_id uuid not null
    references public.conversation_key_epochs (id) on delete restrict,
  epoch_number integer not null check (epoch_number > 0),
  sender_device_id uuid not null
    references public.e2ee_devices (id) on delete restrict,
  ciphertext text not null,
  nonce text not null,
  signature text not null,
  aad_version smallint not null check (aad_version = 1),
  created_at timestamptz not null default now(),
  constraint message_revisions_ciphertext_check
    check (char_length(ciphertext) between 16 and 1048576),
  constraint message_revisions_nonce_check
    check (char_length(nonce) between 16 and 512),
  constraint message_revisions_signature_check
    check (char_length(signature) between 64 and 1024),
  constraint message_revisions_message_revision_key unique (message_id, revision)
);

create index if not exists message_revisions_message_latest_idx
  on public.message_revisions (message_id, revision desc);

alter table public.messages
  drop constraint if exists messages_latest_revision_id_fkey,
  add constraint messages_latest_revision_id_fkey
    foreign key (latest_revision_id)
    references public.message_revisions (id)
    on delete restrict;

create table if not exists public.encrypted_message_reactions (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.messages (id) on delete cascade,
  conversation_id uuid not null
    references public.conversations (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  epoch_id uuid not null
    references public.conversation_key_epochs (id) on delete restrict,
  sender_device_id uuid not null
    references public.e2ee_devices (id) on delete restrict,
  reaction_tag text not null,
  ciphertext text not null,
  nonce text not null,
  signature text not null,
  aad_version smallint not null default 1 check (aad_version = 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint encrypted_message_reactions_tag_check
    check (char_length(reaction_tag) between 16 and 512),
  constraint encrypted_message_reactions_ciphertext_check
    check (char_length(ciphertext) between 16 and 16384),
  constraint encrypted_message_reactions_nonce_check
    check (char_length(nonce) between 16 and 512),
  constraint encrypted_message_reactions_signature_check
    check (char_length(signature) between 64 and 1024),
  constraint encrypted_message_reactions_message_user_tag_key
    unique (message_id, user_id, reaction_tag)
);

create index if not exists encrypted_message_reactions_conversation_idx
  on public.encrypted_message_reactions (
    conversation_id, message_id, created_at
  );

alter table public.messages
  drop constraint if exists messages_e2ee_payload_check,
  add constraint messages_e2ee_payload_check check (
    (
      encryption_version = 0
      and encryption_state = 'legacy'
      and e2ee_epoch_id is null
      and e2ee_epoch_number is null
      and e2ee_sender_device_id is null
      and e2ee_ciphertext is null
      and e2ee_nonce is null
      and e2ee_signature is null
      and e2ee_aad_version is null
      and e2ee_revision = 0
      and latest_revision_id is null
    )
    or (
      encryption_version = 1
      and encryption_state = 'encrypted'
      and e2ee_revision >= 1
      and (
        (
          deleted_at is null
          and body = ''
          and sender_name = ''
          and reply_to_message_id is null
          and is_forwarded = false
          and e2ee_epoch_id is not null
          and e2ee_epoch_number is not null
          and e2ee_sender_device_id is not null
          and e2ee_ciphertext is not null
          and e2ee_nonce is not null
          and e2ee_signature is not null
          and e2ee_aad_version = 1
        )
        or (
          deleted_at is not null
          and body = ''
          and sender_name = ''
          and reply_to_message_id is null
          and is_forwarded = false
          and e2ee_epoch_id is null
          and e2ee_epoch_number is null
          and e2ee_sender_device_id is null
          and e2ee_ciphertext is null
          and e2ee_nonce is null
          and e2ee_signature is null
          and e2ee_aad_version is null
          and latest_revision_id is null
        )
      )
    )
  );

alter table public.messages
  drop constraint if exists messages_media_payload_check,
  add constraint messages_media_payload_check
  check (
    (
      message_type in ('text', 'call')
      and media_bucket is null
      and media_path is null
      and media_mime_type is null
      and media_size_bytes is null
      and media_width is null
      and media_height is null
      and media_duration_ms is null
      and media_waveform is null
      and media_original_name is null
    )
    or (
      message_type in ('image', 'gif')
      and media_bucket = 'chat-media'
      and media_path is not null
      and (
        (
          encryption_version = 0
          and media_mime_type like 'image/%'
          and media_size_bytes between 1 and 15728640
          and media_duration_ms is null
          and media_waveform is null
        )
        or (
          encryption_version = 1
          and media_mime_type is null
          and media_size_bytes is null
          and media_width is null
          and media_height is null
          and media_duration_ms is null
          and media_waveform is null
          and media_original_name is null
        )
      )
    )
    or (
      message_type = 'voice'
      and media_bucket = 'chat-media'
      and media_path is not null
      and (
        (
          encryption_version = 0
          and media_mime_type like 'audio/%'
          and media_size_bytes between 1 and 15728640
          and (media_duration_ms is null or media_duration_ms between 0 and 3600000)
          and (media_waveform is null or jsonb_typeof(media_waveform) = 'array')
        )
        or (
          encryption_version = 1
          and media_mime_type is null
          and media_size_bytes is null
          and media_width is null
          and media_height is null
          and media_duration_ms is null
          and media_waveform is null
          and media_original_name is null
        )
      )
    )
  );

create index if not exists messages_e2ee_conversation_latest_idx
  on public.messages (conversation_id, created_at desc, id desc)
  where encryption_version = 1;

create index if not exists messages_e2ee_epoch_idx
  on public.messages (e2ee_epoch_id)
  where encryption_version = 1;

create table if not exists public.e2ee_rollout_config (
  id boolean primary key default true check (id),
  plaintext_cutover_at timestamptz,
  updated_at timestamptz not null default now()
);

-- Existing rows remain readable, but every new chat write must use protocol
-- v1. Structured call history is inserted only by trusted call-session
-- triggers and never contains a descriptive body.
insert into public.e2ee_rollout_config (id, plaintext_cutover_at)
values (true, now())
on conflict (id) do update
set plaintext_cutover_at = now(),
    updated_at = now();

create or replace function public.assert_e2ee_encoded_value(
  p_value text,
  p_field text,
  p_min_length integer,
  p_max_length integer
)
returns void
language plpgsql
immutable
set search_path = public
as $$
begin
  if p_value is null
    or char_length(p_value) not between p_min_length and p_max_length
    or p_value ~ '[[:space:]]' then
    raise exception '% must be an unwrapped base64/base64url value', p_field
      using errcode = '22023';
  end if;
end;
$$;

create or replace function public.enforce_e2ee_plaintext_cutover()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cutover_at timestamptz;
begin
  select plaintext_cutover_at
  into cutover_at
  from public.e2ee_rollout_config
  where id = true;

  if cutover_at is not null
    and now() >= cutover_at
    and new.encryption_version <> 1 then
    if new.message_type <> 'call' then
      raise exception 'Plaintext chat writes are disabled; update ChatApp to send encrypted messages'
        using errcode = '42501';
    end if;
    if new.body <> ''
      or new.call_event is null
      or new.call_event not in ('started', 'ended', 'failed', 'rejected') then
      raise exception 'Call history must use a structured event with no message body'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists on_message_enforce_e2ee_plaintext_cutover
  on public.messages;
create trigger on_message_enforce_e2ee_plaintext_cutover
  before insert on public.messages
  for each row execute function public.enforce_e2ee_plaintext_cutover();

create or replace function public.ensure_conversation_crypto_state()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.conversation_crypto_state (conversation_id)
  values (new.id)
  on conflict (conversation_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_conversation_create_e2ee_state
  on public.conversations;
create trigger on_conversation_create_e2ee_state
  after insert on public.conversations
  for each row execute function public.ensure_conversation_crypto_state();

insert into public.conversation_crypto_state (conversation_id)
select id
from public.conversations
on conflict (conversation_id) do nothing;

create or replace function public.mark_conversation_membership_rekey()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  target_conversation_id uuid := coalesce(new.conversation_id, old.conversation_id);
begin
  if tg_op = 'UPDATE'
    and new.joined_at is not distinct from old.joined_at
    and new.left_at is not distinct from old.left_at then
    return new;
  end if;

  if not exists (
    select 1 from public.conversations where id = target_conversation_id
  ) then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  insert into public.conversation_crypto_state (conversation_id)
  values (target_conversation_id)
  on conflict (conversation_id) do nothing;

  update public.conversation_crypto_state
  set membership_version = membership_version + 1,
      rekey_required = true,
      updated_at = now()
  where conversation_id = target_conversation_id;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists on_conversation_membership_e2ee_rekey
  on public.conversation_members;
create trigger on_conversation_membership_e2ee_rekey
  after insert or update or delete on public.conversation_members
  for each row execute function public.mark_conversation_membership_rekey();

create or replace function public.mark_e2ee_rekey_for_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.conversation_crypto_state as state
  set rekey_required = true,
      updated_at = now()
  from public.conversation_members as members
  where members.conversation_id = state.conversation_id
    and members.user_id = p_user_id
    and members.left_at is null;
end;
$$;

alter table public.e2ee_accounts enable row level security;
alter table public.e2ee_devices enable row level security;
alter table public.conversation_crypto_state enable row level security;
alter table public.conversation_key_epochs enable row level security;
alter table public.conversation_key_envelopes enable row level security;
alter table public.message_revisions enable row level security;
alter table public.encrypted_message_reactions enable row level security;
alter table public.e2ee_rollout_config enable row level security;

revoke all on table public.e2ee_accounts,
  public.e2ee_devices,
  public.conversation_crypto_state,
  public.conversation_key_epochs,
  public.conversation_key_envelopes,
  public.message_revisions,
  public.encrypted_message_reactions,
  public.e2ee_rollout_config
from anon, authenticated;

grant select on table public.e2ee_accounts,
  public.e2ee_devices,
  public.conversation_crypto_state,
  public.conversation_key_epochs,
  public.message_revisions,
  public.encrypted_message_reactions
to authenticated;

drop policy if exists "Users can read their E2EE account" on public.e2ee_accounts;
create policy "Users can read their E2EE account"
  on public.e2ee_accounts
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists "Users can read their E2EE devices" on public.e2ee_devices;
create policy "Users can read their E2EE devices"
  on public.e2ee_devices
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists "Conversation members can read crypto state"
  on public.conversation_crypto_state;
create policy "Conversation members can read crypto state"
  on public.conversation_crypto_state
  for select to authenticated
  using (public.is_conversation_member(conversation_id, auth.uid()));

drop policy if exists "Conversation members can read E2EE epochs"
  on public.conversation_key_epochs;
create policy "Conversation members can read E2EE epochs"
  on public.conversation_key_epochs
  for select to authenticated
  using (public.is_conversation_member(conversation_id, auth.uid()));

drop policy if exists "Conversation members can read encrypted revisions"
  on public.message_revisions;
create policy "Conversation members can read encrypted revisions"
  on public.message_revisions
  for select to authenticated
  using (
    exists (
      select 1
      from public.messages
      where messages.id = message_revisions.message_id
        and public.is_conversation_member(
          messages.conversation_id,
          auth.uid(),
          messages.created_at
        )
        and public.is_conversation_member(messages.conversation_id, auth.uid())
    )
  );

drop policy if exists "Conversation members can read encrypted reactions"
  on public.encrypted_message_reactions;
create policy "Conversation members can read encrypted reactions"
  on public.encrypted_message_reactions
  for select to authenticated
  using (
    public.is_conversation_member(conversation_id, auth.uid())
    and exists (
      select 1
      from public.messages
      where messages.id = encrypted_message_reactions.message_id
        and public.is_conversation_member(
          messages.conversation_id,
          auth.uid(),
          messages.created_at
        )
    )
  );

drop policy if exists "Users can send legacy conversation messages" on public.messages;
drop policy if exists "Users can send own conversation messages" on public.messages;

-- A queued encrypted attachment may have been uploaded before its message
-- row exists. Its sender needs read/update access to retry the same opaque
-- object; other members only gain access once a message references it.
drop policy if exists "Conversation members can read chat media" on storage.objects;
create policy "Conversation members can read chat media"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'chat-media'
    and public.is_conversation_member(
      ((storage.foldername(name))[1])::uuid,
      auth.uid()
    )
    and (
      (storage.foldername(name))[2] = auth.uid()::text
      or exists (
        select 1
        from public.messages
        where messages.media_path = objects.name
          and messages.conversation_id =
            ((storage.foldername(objects.name))[1])::uuid
          and public.is_conversation_member(
            messages.conversation_id,
            auth.uid(),
            messages.created_at
          )
      )
    )
  );

drop policy if exists "Conversation senders can update chat media" on storage.objects;
create policy "Conversation senders can update chat media"
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'chat-media'
    and (storage.foldername(name))[2] = auth.uid()::text
    and public.is_conversation_member(
      ((storage.foldername(name))[1])::uuid,
      auth.uid()
    )
  )
  with check (
    bucket_id = 'chat-media'
    and (storage.foldername(name))[2] = auth.uid()::text
    and public.is_conversation_member(
      ((storage.foldername(name))[1])::uuid,
      auth.uid()
    )
  );

create or replace function public.register_e2ee_account(
  p_recovery_public_key text,
  p_signing_public_key text,
  p_protocol_version integer default 1
)
returns public.e2ee_accounts
language plpgsql
security definer
set search_path = public
as $$
declare
  active_user_id uuid := auth.uid();
  stored_account public.e2ee_accounts;
begin
  if active_user_id is null then
    raise exception 'Authentication is required to register an E2EE account';
  end if;
  if p_protocol_version <> 1 then
    raise exception 'Unsupported E2EE protocol version';
  end if;

  perform public.assert_e2ee_encoded_value(
    p_recovery_public_key, 'recovery_public_key', 40, 512
  );
  perform public.assert_e2ee_encoded_value(
    p_signing_public_key, 'signing_public_key', 40, 512
  );

  select *
  into stored_account
  from public.e2ee_accounts
  where user_id = active_user_id
  for update;

  if found then
    if stored_account.recovery_public_key <> p_recovery_public_key
      or stored_account.signing_public_key <> p_signing_public_key
      or stored_account.protocol_version <> p_protocol_version then
      raise exception 'The account identity is immutable; restore the existing recovery phrase';
    end if;

    update public.e2ee_accounts
    set updated_at = now()
    where user_id = active_user_id
    returning * into stored_account;

    return stored_account;
  end if;

  insert into public.e2ee_accounts (
    user_id, protocol_version, recovery_public_key, signing_public_key
  )
  values (
    active_user_id, p_protocol_version, p_recovery_public_key, p_signing_public_key
  )
  returning * into stored_account;

  return stored_account;
end;
$$;

create or replace function public.register_e2ee_device(
  p_device_id uuid,
  p_encryption_public_key text,
  p_signing_public_key text,
  p_certificate text,
  p_label text default null,
  p_protocol_version integer default 1
)
returns public.e2ee_devices
language plpgsql
security definer
set search_path = public
as $$
declare
  active_user_id uuid := auth.uid();
  normalized_device_id uuid := coalesce(p_device_id, gen_random_uuid());
  normalized_label text := nullif(trim(coalesce(p_label, '')), '');
  stored_device public.e2ee_devices;
begin
  if active_user_id is null then
    raise exception 'Authentication is required to register an E2EE device';
  end if;
  if p_protocol_version <> 1 then
    raise exception 'Unsupported E2EE protocol version';
  end if;
  if not exists (
    select 1 from public.e2ee_accounts where user_id = active_user_id
  ) then
    raise exception 'Register the E2EE account before registering a device';
  end if;
  if normalized_label is not null and char_length(normalized_label) > 120 then
    raise exception 'Device labels must be at most 120 characters';
  end if;

  perform public.assert_e2ee_encoded_value(
    p_encryption_public_key, 'encryption_public_key', 40, 512
  );
  perform public.assert_e2ee_encoded_value(
    p_signing_public_key, 'signing_public_key', 40, 512
  );
  perform public.assert_e2ee_encoded_value(p_certificate, 'certificate', 64, 1024);

  select *
  into stored_device
  from public.e2ee_devices
  where id = normalized_device_id
  for update;

  if found then
    if stored_device.user_id <> active_user_id then
      raise exception 'That E2EE device belongs to another account';
    end if;
    if stored_device.revoked_at is not null then
      raise exception 'A revoked E2EE device cannot be reactivated';
    end if;
    if stored_device.encryption_public_key <> p_encryption_public_key
      or stored_device.signing_public_key <> p_signing_public_key
      or stored_device.certificate <> p_certificate
      or stored_device.protocol_version <> p_protocol_version then
      raise exception 'E2EE device keys are immutable; register a new device id';
    end if;

    update public.e2ee_devices
    set label = normalized_label,
        last_seen_at = now()
    where id = normalized_device_id
    returning * into stored_device;

    return stored_device;
  end if;

  insert into public.e2ee_devices (
    id,
    user_id,
    protocol_version,
    encryption_public_key,
    signing_public_key,
    certificate,
    label
  )
  values (
    normalized_device_id,
    active_user_id,
    p_protocol_version,
    p_encryption_public_key,
    p_signing_public_key,
    p_certificate,
    normalized_label
  )
  returning * into stored_device;

  perform public.mark_e2ee_rekey_for_user(active_user_id);
  return stored_device;
end;
$$;

-- Device certificates are verified at the Edge boundary with WebCrypto before
-- this service-only function is reached. Keeping the database write behind a
-- service-role RPC prevents authenticated clients from bypassing that
-- verification and registering an uncertified key that could block rekeys.
create or replace function public.register_verified_e2ee_device(
  p_user_id uuid,
  p_device_id uuid,
  p_encryption_public_key text,
  p_signing_public_key text,
  p_certificate text,
  p_label text default null,
  p_protocol_version integer default 1
)
returns public.e2ee_devices
language plpgsql
security definer
set search_path = public
as $$
declare
  normalized_label text := nullif(trim(coalesce(p_label, '')), '');
  stored_device public.e2ee_devices;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Only the verified E2EE device registration service may register a device'
      using errcode = '42501';
  end if;
  if p_user_id is null or p_device_id is null then
    raise exception 'An E2EE device and account are required';
  end if;
  if p_protocol_version <> 1 then
    raise exception 'Unsupported E2EE protocol version';
  end if;
  if not exists (
    select 1 from public.e2ee_accounts where user_id = p_user_id
  ) then
    raise exception 'Register the E2EE account before registering a device';
  end if;
  if normalized_label is not null and char_length(normalized_label) > 120 then
    raise exception 'Device labels must be at most 120 characters';
  end if;

  perform public.assert_e2ee_encoded_value(
    p_encryption_public_key, 'encryption_public_key', 40, 512
  );
  perform public.assert_e2ee_encoded_value(
    p_signing_public_key, 'signing_public_key', 40, 512
  );
  perform public.assert_e2ee_encoded_value(p_certificate, 'certificate', 64, 1024);

  select *
  into stored_device
  from public.e2ee_devices
  where id = p_device_id
  for update;

  if found then
    if stored_device.user_id <> p_user_id then
      raise exception 'That E2EE device belongs to another account';
    end if;
    if stored_device.revoked_at is not null then
      raise exception 'A revoked E2EE device cannot be reactivated';
    end if;
    if stored_device.encryption_public_key <> p_encryption_public_key
      or stored_device.signing_public_key <> p_signing_public_key
      or stored_device.certificate <> p_certificate
      or stored_device.protocol_version <> p_protocol_version then
      raise exception 'E2EE device keys are immutable; register a new device id';
    end if;

    update public.e2ee_devices
    set label = normalized_label,
        last_seen_at = now()
    where id = p_device_id
    returning * into stored_device;

    return stored_device;
  end if;

  insert into public.e2ee_devices (
    id,
    user_id,
    protocol_version,
    encryption_public_key,
    signing_public_key,
    certificate,
    label
  )
  values (
    p_device_id,
    p_user_id,
    p_protocol_version,
    p_encryption_public_key,
    p_signing_public_key,
    p_certificate,
    normalized_label
  )
  returning * into stored_device;

  perform public.mark_e2ee_rekey_for_user(p_user_id);
  return stored_device;
end;
$$;

create or replace function public.revoke_e2ee_device(p_device_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  active_user_id uuid := auth.uid();
begin
  if active_user_id is null then
    raise exception 'Authentication is required to revoke an E2EE device';
  end if;

  update public.e2ee_devices
  set revoked_at = now()
  where id = p_device_id
    and user_id = active_user_id
    and revoked_at is null;

  if not found then
    raise exception 'The active E2EE device was not found';
  end if;

  perform public.mark_e2ee_rekey_for_user(active_user_id);
end;
$$;

create or replace function public.get_conversation_e2ee_key_material(
  p_conversation_id uuid
)
returns table (
  recipient_kind text,
  recipient_user_id uuid,
  recipient_device_id uuid,
  encryption_public_key text,
  signing_public_key text,
  device_certificate text,
  account_signing_public_key text,
  account_recovery_public_key text,
  device_created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null
    or not public.is_conversation_member(p_conversation_id, auth.uid()) then
    raise exception 'You are not an active conversation member';
  end if;

  return query
  select
    'recovery'::text,
    members.user_id,
    null::uuid,
    accounts.recovery_public_key,
    null::text,
    null::text,
    accounts.signing_public_key,
    accounts.recovery_public_key,
    null::timestamptz
  from public.conversation_members as members
  join public.e2ee_accounts as accounts
    on accounts.user_id = members.user_id
  where members.conversation_id = p_conversation_id
    and members.left_at is null

  union all

  select
    'device'::text,
    devices.user_id,
    devices.id,
    devices.encryption_public_key,
    devices.signing_public_key,
    devices.certificate,
    accounts.signing_public_key,
    accounts.recovery_public_key,
    devices.created_at
  from public.conversation_members as members
  join public.e2ee_accounts as accounts
    on accounts.user_id = members.user_id
  join public.e2ee_devices as devices
    on devices.user_id = members.user_id
    and devices.revoked_at is null
  where members.conversation_id = p_conversation_id
    and members.left_at is null
  order by 1, 2, 3 nulls first;
end;
$$;

create or replace function public.get_e2ee_device_envelopes(
  p_device_id uuid
)
returns table (
  conversation_id uuid,
  epoch_id uuid,
  epoch_number integer,
  membership_version integer,
  commitment text,
  epoch_signature text,
  created_by_user_id uuid,
  created_by_device_id uuid,
  creator_device_encryption_public_key text,
  creator_device_signing_public_key text,
  creator_device_certificate text,
  creator_account_signing_public_key text,
  envelope_ciphertext text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not exists (
    select 1
    from public.e2ee_devices
    where id = p_device_id
      and user_id = auth.uid()
      and revoked_at is null
  ) then
    raise exception 'The active E2EE device was not found';
  end if;

  return query
  select
    envelopes.conversation_id,
    epochs.id,
    epochs.epoch_number,
    epochs.membership_version,
    epochs.commitment,
    epochs.signature,
    epochs.created_by_user_id,
    epochs.created_by_device_id,
    creator_device.encryption_public_key,
    creator_device.signing_public_key,
    creator_device.certificate,
    creator_account.signing_public_key,
    envelopes.ciphertext,
    envelopes.created_at
  from public.conversation_key_envelopes as envelopes
  join public.conversation_key_epochs as epochs
    on epochs.id = envelopes.epoch_id
  join public.e2ee_devices as creator_device
    on creator_device.id = epochs.created_by_device_id
  join public.e2ee_accounts as creator_account
    on creator_account.user_id = epochs.created_by_user_id
  where envelopes.recipient_kind = 'device'
    and envelopes.recipient_device_id = p_device_id
    and public.is_conversation_member(envelopes.conversation_id, auth.uid())
  order by envelopes.created_at, envelopes.id;
end;
$$;

create or replace function public.get_e2ee_recovery_envelopes()
returns table (
  conversation_id uuid,
  epoch_id uuid,
  epoch_number integer,
  membership_version integer,
  commitment text,
  epoch_signature text,
  created_by_user_id uuid,
  created_by_device_id uuid,
  creator_device_encryption_public_key text,
  creator_device_signing_public_key text,
  creator_device_certificate text,
  creator_account_signing_public_key text,
  envelope_ciphertext text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication is required to retrieve recovery envelopes';
  end if;

  return query
  select
    envelopes.conversation_id,
    epochs.id,
    epochs.epoch_number,
    epochs.membership_version,
    epochs.commitment,
    epochs.signature,
    epochs.created_by_user_id,
    epochs.created_by_device_id,
    creator_device.encryption_public_key,
    creator_device.signing_public_key,
    creator_device.certificate,
    creator_account.signing_public_key,
    envelopes.ciphertext,
    envelopes.created_at
  from public.conversation_key_envelopes as envelopes
  join public.conversation_key_epochs as epochs
    on epochs.id = envelopes.epoch_id
  join public.e2ee_devices as creator_device
    on creator_device.id = epochs.created_by_device_id
  join public.e2ee_accounts as creator_account
    on creator_account.user_id = epochs.created_by_user_id
  where envelopes.recipient_kind = 'recovery'
    and envelopes.recipient_user_id = auth.uid()
    and public.is_conversation_member(envelopes.conversation_id, auth.uid())
  order by envelopes.created_at, envelopes.id;
end;
$$;

create or replace function public.get_conversation_e2ee_device_identities(
  p_conversation_id uuid,
  p_device_ids uuid[]
)
returns table (
  device_id uuid,
  user_id uuid,
  encryption_public_key text,
  signing_public_key text,
  certificate text,
  account_signing_public_key text,
  revoked_at timestamptz,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null
    or not public.is_conversation_member(p_conversation_id, auth.uid()) then
    raise exception 'You are not an active conversation member';
  end if;
  if p_device_ids is null
    or cardinality(p_device_ids) = 0
    or cardinality(p_device_ids) > 200 then
    raise exception 'Request between one and 200 E2EE device identities';
  end if;

  return query
  select
    devices.id,
    devices.user_id,
    devices.encryption_public_key,
    devices.signing_public_key,
    devices.certificate,
    accounts.signing_public_key,
    devices.revoked_at,
    devices.created_at
  from public.e2ee_devices as devices
  join public.e2ee_accounts as accounts
    on accounts.user_id = devices.user_id
  where devices.id = any(p_device_ids)
    and exists (
      select 1
      from public.conversation_members as members
      where members.conversation_id = p_conversation_id
        and members.user_id = devices.user_id
    )
  order by devices.id;
end;
$$;

create or replace function public.publish_conversation_epoch(
  p_conversation_id uuid,
  p_epoch_id uuid,
  p_epoch_number integer,
  p_membership_version integer,
  p_creator_device_id uuid,
  p_commitment text,
  p_signature text,
  p_envelopes jsonb
)
returns table (
  epoch_id uuid,
  epoch_number integer,
  membership_version integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  active_user_id uuid := auth.uid();
  crypto_state public.conversation_crypto_state;
  envelope record;
  expected_recipient_count bigint;
  submitted_recipient_count bigint;
begin
  if active_user_id is null
    or not public.is_conversation_member(p_conversation_id, active_user_id) then
    raise exception 'You are not an active conversation member';
  end if;
  if p_epoch_number is null or p_epoch_number < 1 then
    raise exception 'Epoch numbers must start at 1';
  end if;
  if p_epoch_id is null then
    raise exception 'Epoch ids must be client-generated UUIDs';
  end if;
  if p_membership_version is null or p_membership_version < 0 then
    raise exception 'A valid membership version is required';
  end if;
  if jsonb_typeof(p_envelopes) <> 'array' then
    raise exception 'Epoch envelopes must be a JSON array';
  end if;
  if jsonb_array_length(p_envelopes) > 1000 then
    raise exception 'Too many epoch envelopes';
  end if;

  perform public.assert_e2ee_encoded_value(p_commitment, 'commitment', 16, 4096);
  perform public.assert_e2ee_encoded_value(p_signature, 'signature', 64, 1024);

  -- Membership writers lock a member row and then crypto state. Acquire the
  -- same locks in the same order so no stale membership can be sealed.
  perform 1
  from public.conversation_members
  where conversation_id = p_conversation_id
  for update;

  select *
  into crypto_state
  from public.conversation_crypto_state
  where conversation_id = p_conversation_id
  for update;

  if not found then
    insert into public.conversation_crypto_state (conversation_id)
    values (p_conversation_id);
    select *
    into crypto_state
    from public.conversation_crypto_state
    where conversation_id = p_conversation_id
    for update;
  end if;

  if crypto_state.membership_version <> p_membership_version then
    raise exception 'Membership changed; fetch recipients and create a new epoch';
  end if;
  if p_epoch_number <> coalesce(crypto_state.active_epoch_number, 0) + 1 then
    raise exception 'Epoch number must immediately follow the active epoch';
  end if;
  if not exists (
    select 1
    from public.e2ee_devices
    where id = p_creator_device_id
      and user_id = active_user_id
      and revoked_at is null
  ) then
    raise exception 'The publishing E2EE device is not active';
  end if;

  if exists (
    select 1
    from public.conversation_members as members
    left join public.e2ee_accounts as accounts
      on accounts.user_id = members.user_id
    where members.conversation_id = p_conversation_id
      and members.left_at is null
      and accounts.user_id is null
  ) then
    raise exception 'Every active member must complete E2EE setup before rekeying';
  end if;

  if exists (
    select 1
    from public.conversation_members as members
    where members.conversation_id = p_conversation_id
      and members.left_at is null
      and not exists (
        select 1
        from public.e2ee_devices as devices
        where devices.user_id = members.user_id
          and devices.revoked_at is null
      )
  ) then
    raise exception 'Every active member needs at least one active E2EE device';
  end if;

  for envelope in
    select *
    from jsonb_to_recordset(p_envelopes) as payload(
      recipient_kind text,
      recipient_user_id uuid,
      recipient_device_id uuid,
      ciphertext text
    )
  loop
    if envelope.recipient_kind not in ('device', 'recovery')
      or envelope.recipient_user_id is null then
      raise exception 'Each epoch envelope needs a valid recipient';
    end if;
    if envelope.recipient_kind = 'device'
      and envelope.recipient_device_id is null then
      raise exception 'Device envelopes require a recipient device id';
    end if;
    if envelope.recipient_kind = 'recovery'
      and envelope.recipient_device_id is not null then
      raise exception 'Recovery envelopes cannot include a device id';
    end if;
    perform public.assert_e2ee_encoded_value(
      envelope.ciphertext, 'envelope ciphertext', 40, 16384
    );
  end loop;

  if exists (
    select 1
    from jsonb_to_recordset(p_envelopes) as payload(
      recipient_kind text,
      recipient_user_id uuid,
      recipient_device_id uuid,
      ciphertext text
    )
    group by recipient_kind, recipient_user_id, recipient_device_id
    having count(*) > 1
  ) then
    raise exception 'Epoch envelopes cannot contain duplicate recipients';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_envelopes) as payload(
      recipient_kind text,
      recipient_user_id uuid,
      recipient_device_id uuid,
      ciphertext text
    )
    where (
      payload.recipient_kind = 'recovery'
      and not exists (
        select 1
        from public.conversation_members as members
        join public.e2ee_accounts as accounts
          on accounts.user_id = members.user_id
        where members.conversation_id = p_conversation_id
          and members.user_id = payload.recipient_user_id
          and members.left_at is null
      )
    )
    or (
      payload.recipient_kind = 'device'
      and not exists (
        select 1
        from public.conversation_members as members
        join public.e2ee_devices as devices
          on devices.user_id = members.user_id
        where members.conversation_id = p_conversation_id
          and members.user_id = payload.recipient_user_id
          and members.left_at is null
          and devices.id = payload.recipient_device_id
          and devices.revoked_at is null
      )
    )
  ) then
    raise exception 'Epoch envelopes must target exactly the active recipient keys';
  end if;

  select
    (
      select count(*)
      from public.conversation_members as members
      where members.conversation_id = p_conversation_id
        and members.left_at is null
    )
    + (
      select count(*)
      from public.conversation_members as members
      join public.e2ee_devices as devices
        on devices.user_id = members.user_id
        and devices.revoked_at is null
      where members.conversation_id = p_conversation_id
        and members.left_at is null
    )
  into expected_recipient_count;

  select count(*)
  into submitted_recipient_count
  from jsonb_to_recordset(p_envelopes) as payload(
    recipient_kind text,
    recipient_user_id uuid,
    recipient_device_id uuid,
    ciphertext text
  );

  if submitted_recipient_count <> expected_recipient_count then
    raise exception 'Epoch envelopes must cover every active device and recovery key';
  end if;

  insert into public.conversation_key_epochs (
    id,
    conversation_id,
    epoch_number,
    membership_version,
    created_by_user_id,
    created_by_device_id,
    commitment,
    signature
  )
  values (
    p_epoch_id,
    p_conversation_id,
    p_epoch_number,
    p_membership_version,
    active_user_id,
    p_creator_device_id,
    p_commitment,
    p_signature
  );

  insert into public.conversation_key_envelopes (
    epoch_id,
    conversation_id,
    recipient_kind,
    recipient_user_id,
    recipient_device_id,
    ciphertext
  )
  select
    p_epoch_id,
    p_conversation_id,
    payload.recipient_kind,
    payload.recipient_user_id,
    payload.recipient_device_id,
    payload.ciphertext
  from jsonb_to_recordset(p_envelopes) as payload(
    recipient_kind text,
    recipient_user_id uuid,
    recipient_device_id uuid,
    ciphertext text
  );

  update public.conversation_crypto_state
  set active_epoch_number = p_epoch_number,
      active_epoch_id = p_epoch_id,
      rekey_required = false,
      updated_at = now()
  where conversation_id = p_conversation_id;

  return query select p_epoch_id, p_epoch_number, p_membership_version;
end;
$$;

drop function if exists public.send_encrypted_message(
  uuid, uuid, uuid, text, text, text, text, text, text, uuid, boolean, uuid
);

create or replace function public.send_encrypted_message(
  p_conversation_id uuid,
  p_sender_device_id uuid,
  p_epoch_id uuid,
  p_ciphertext text,
  p_nonce text,
  p_signature text,
  p_message_type text,
  p_media_bucket text default null,
  p_media_path text default null,
  p_message_id uuid default null
)
returns public.messages
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  active_user_id uuid := auth.uid();
  crypto_state public.conversation_crypto_state;
  stored_message public.messages;
  inserted_revision_id uuid;
  generated_message_id uuid := coalesce(p_message_id, gen_random_uuid());
begin
  if active_user_id is null
    or not public.is_conversation_member(p_conversation_id, active_user_id) then
    raise exception 'You are not an active conversation member';
  end if;
  if p_message_type is null or p_message_type not in ('text', 'image', 'gif', 'voice') then
    raise exception 'Encrypted messages must have a supported chat message type';
  end if;

  perform public.assert_e2ee_encoded_value(p_ciphertext, 'ciphertext', 16, 1048576);
  perform public.assert_e2ee_encoded_value(p_nonce, 'nonce', 16, 512);
  perform public.assert_e2ee_encoded_value(p_signature, 'signature', 64, 1024);

  if p_message_type = 'text' then
    if p_media_bucket is not null or p_media_path is not null then
      raise exception 'Text messages cannot include media routing data';
    end if;
  else
    if p_media_bucket is distinct from 'chat-media'
      or nullif(trim(coalesce(p_media_path, '')), '') is null
      or p_media_path not like (
        p_conversation_id::text || '/' || active_user_id::text || '/%'
      ) then
      raise exception 'Encrypted media must use an opaque object in the sender conversation folder';
    end if;
    if not exists (
      select 1
      from storage.objects
      where bucket_id = 'chat-media'
        and name = p_media_path
        and coalesce(
          metadata ->> 'mimetype',
          metadata ->> 'contentType',
          ''
        ) = 'application/octet-stream'
    ) then
      raise exception 'Upload the encrypted media as an application/octet-stream object before sending';
    end if;
  end if;

  if p_message_id is not null then
    select *
    into stored_message
    from public.messages
    where id = p_message_id;

    if found then
      if stored_message.sender_id = active_user_id
        and stored_message.conversation_id = p_conversation_id
        and stored_message.encryption_version = 1
        and stored_message.e2ee_ciphertext = p_ciphertext
        and stored_message.e2ee_nonce = p_nonce
        and stored_message.e2ee_signature = p_signature then
        return stored_message;
      end if;
      raise exception 'The supplied encrypted message id already belongs to another payload';
    end if;
  end if;

  select *
  into crypto_state
  from public.conversation_crypto_state
  where conversation_id = p_conversation_id
  for update;

  if not found
    or crypto_state.rekey_required
    or crypto_state.active_epoch_id is distinct from p_epoch_id then
    raise exception 'Conversation keys changed; publish or fetch the current epoch before sending';
  end if;
  if not exists (
    select 1
    from public.conversation_key_epochs
    where id = p_epoch_id
      and conversation_id = p_conversation_id
      and epoch_number = crypto_state.active_epoch_number
  ) then
    raise exception 'The selected E2EE epoch is not active for this conversation';
  end if;
  if not exists (
    select 1
    from public.e2ee_devices
    where id = p_sender_device_id
      and user_id = active_user_id
      and revoked_at is null
  ) then
    raise exception 'The sending E2EE device is not active';
  end if;

  insert into public.messages (
    id,
    conversation_id,
    sender_id,
    sender_name,
    body,
    message_type,
    media_bucket,
    media_path,
    reply_to_message_id,
    is_forwarded,
    encryption_version,
    encryption_state,
    e2ee_epoch_id,
    e2ee_epoch_number,
    e2ee_sender_device_id,
    e2ee_ciphertext,
    e2ee_nonce,
    e2ee_signature,
    e2ee_aad_version,
    e2ee_revision
  )
  values (
    generated_message_id,
    p_conversation_id,
    active_user_id,
    '',
    '',
    p_message_type,
    p_media_bucket,
    p_media_path,
    null,
    false,
    1,
    'encrypted',
    p_epoch_id,
    crypto_state.active_epoch_number,
    p_sender_device_id,
    p_ciphertext,
    p_nonce,
    p_signature,
    1,
    1
  )
  returning * into stored_message;

  insert into public.message_revisions (
    message_id,
    revision,
    epoch_id,
    epoch_number,
    sender_device_id,
    ciphertext,
    nonce,
    signature,
    aad_version
  )
  values (
    stored_message.id,
    1,
    p_epoch_id,
    crypto_state.active_epoch_number,
    p_sender_device_id,
    p_ciphertext,
    p_nonce,
    p_signature,
    1
  )
  returning id into inserted_revision_id;

  update public.messages
  set latest_revision_id = inserted_revision_id
  where id = stored_message.id
  returning * into stored_message;

  return stored_message;
end;
$$;

drop function if exists public.edit_encrypted_message(uuid, uuid, uuid, text, text, text);

create or replace function public.edit_encrypted_message(
  p_message_id uuid,
  p_sender_device_id uuid,
  p_epoch_id uuid,
  p_revision integer,
  p_ciphertext text,
  p_nonce text,
  p_signature text
)
returns public.message_revisions
language plpgsql
security definer
set search_path = public
as $$
declare
  active_user_id uuid := auth.uid();
  target_message public.messages;
  crypto_state public.conversation_crypto_state;
  stored_revision public.message_revisions;
  next_revision integer;
begin
  if active_user_id is null then
    raise exception 'Authentication is required to edit an encrypted message';
  end if;
  perform public.assert_e2ee_encoded_value(p_ciphertext, 'ciphertext', 16, 1048576);
  perform public.assert_e2ee_encoded_value(p_nonce, 'nonce', 16, 512);
  perform public.assert_e2ee_encoded_value(p_signature, 'signature', 64, 1024);
  if p_revision is null or p_revision < 2 then
    raise exception 'Encrypted edit revisions must start at 2';
  end if;

  select *
  into target_message
  from public.messages
  where id = p_message_id
    and sender_id = active_user_id
  for update;

  if not found
    or target_message.encryption_version <> 1
    or target_message.deleted_at is not null
    or not public.is_conversation_member(target_message.conversation_id, active_user_id) then
    raise exception 'The encrypted message is missing or cannot be edited';
  end if;

  select *
  into crypto_state
  from public.conversation_crypto_state
  where conversation_id = target_message.conversation_id
  for update;

  if not found
    or crypto_state.rekey_required
    or crypto_state.active_epoch_id is distinct from p_epoch_id then
    raise exception 'Conversation keys changed; publish or fetch the current epoch before editing';
  end if;
  if not exists (
    select 1
    from public.e2ee_devices
    where id = p_sender_device_id
      and user_id = active_user_id
      and revoked_at is null
  ) then
    raise exception 'The editing E2EE device is not active';
  end if;

  next_revision := target_message.e2ee_revision + 1;
  if p_revision <> next_revision then
    raise exception 'Encrypted message changed; fetch it and encrypt the next revision';
  end if;
  insert into public.message_revisions (
    message_id,
    revision,
    epoch_id,
    epoch_number,
    sender_device_id,
    ciphertext,
    nonce,
    signature,
    aad_version
  )
  values (
    target_message.id,
    next_revision,
    p_epoch_id,
    crypto_state.active_epoch_number,
    p_sender_device_id,
    p_ciphertext,
    p_nonce,
    p_signature,
    1
  )
  returning * into stored_revision;

  update public.messages
  set e2ee_epoch_id = p_epoch_id,
      e2ee_epoch_number = crypto_state.active_epoch_number,
      e2ee_sender_device_id = p_sender_device_id,
      e2ee_ciphertext = p_ciphertext,
      e2ee_nonce = p_nonce,
      e2ee_signature = p_signature,
      e2ee_aad_version = 1,
      e2ee_revision = next_revision,
      latest_revision_id = stored_revision.id,
      edited_at = now()
  where id = target_message.id;

  return stored_revision;
end;
$$;

create or replace function public.set_encrypted_reaction(
  p_message_id uuid,
  p_sender_device_id uuid,
  p_epoch_id uuid,
  p_reaction_tag text,
  p_is_active boolean,
  p_ciphertext text default null,
  p_nonce text default null,
  p_signature text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  active_user_id uuid := auth.uid();
  target_message public.messages;
  crypto_state public.conversation_crypto_state;
begin
  if active_user_id is null then
    raise exception 'Authentication is required to react to an encrypted message';
  end if;
  perform public.assert_e2ee_encoded_value(p_reaction_tag, 'reaction tag', 16, 512);

  select *
  into target_message
  from public.messages
  where id = p_message_id
  for update;

  if not found
    or target_message.encryption_version <> 1
    or target_message.deleted_at is not null
    or not public.is_conversation_member(target_message.conversation_id, active_user_id)
    or not public.is_conversation_member(
      target_message.conversation_id,
      active_user_id,
      target_message.created_at
    ) then
    raise exception 'The encrypted message is missing or cannot be reacted to';
  end if;

  select *
  into crypto_state
  from public.conversation_crypto_state
  where conversation_id = target_message.conversation_id
  for update;

  if not found
    or crypto_state.rekey_required
    or crypto_state.active_epoch_id is distinct from p_epoch_id then
    raise exception 'Conversation keys changed; publish or fetch the current epoch before reacting';
  end if;
  if not exists (
    select 1
    from public.e2ee_devices
    where id = p_sender_device_id
      and user_id = active_user_id
      and revoked_at is null
  ) then
    raise exception 'The reacting E2EE device is not active';
  end if;

  if not coalesce(p_is_active, false) then
    delete from public.encrypted_message_reactions
    where message_id = target_message.id
      and user_id = active_user_id
      and reaction_tag = p_reaction_tag;
    return false;
  end if;

  perform public.assert_e2ee_encoded_value(
    p_ciphertext, 'reaction ciphertext', 16, 16384
  );
  perform public.assert_e2ee_encoded_value(p_nonce, 'reaction nonce', 16, 512);
  perform public.assert_e2ee_encoded_value(
    p_signature, 'reaction signature', 64, 1024
  );

  insert into public.encrypted_message_reactions (
    message_id,
    conversation_id,
    user_id,
    epoch_id,
    sender_device_id,
    reaction_tag,
    ciphertext,
    nonce,
    signature
  )
  values (
    target_message.id,
    target_message.conversation_id,
    active_user_id,
    p_epoch_id,
    p_sender_device_id,
    p_reaction_tag,
    p_ciphertext,
    p_nonce,
    p_signature
  )
  on conflict (message_id, user_id, reaction_tag) do update
  set epoch_id = excluded.epoch_id,
      sender_device_id = excluded.sender_device_id,
      ciphertext = excluded.ciphertext,
      nonce = excluded.nonce,
      signature = excluded.signature,
      updated_at = now();

  return true;
end;
$$;

create or replace function public.edit_message(
  target_message_id uuid,
  new_body text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  active_user_id uuid := auth.uid();
  target_type text;
  target_encryption_version integer;
begin
  if active_user_id is null then
    raise exception 'Authentication required';
  end if;

  select message_type, encryption_version
  into target_type, target_encryption_version
  from public.messages
  where id = target_message_id
    and sender_id = active_user_id
    and deleted_at is null
    and public.is_conversation_member(conversation_id, active_user_id)
    and public.is_conversation_member(
      conversation_id,
      active_user_id,
      created_at
    )
  for update;

  if not found then
    raise exception 'Message is missing or cannot be edited';
  end if;
  raise exception 'Legacy messages are read-only; encrypted messages use edit_encrypted_message';
end;
$$;

create or replace function public.delete_message(target_message_id uuid)
returns table (media_bucket text, media_path text)
language plpgsql
security definer
set search_path = public
as $$
declare
  active_user_id uuid := auth.uid();
  stored_bucket text;
  stored_path text;
  target_encryption_version integer;
begin
  if active_user_id is null then
    raise exception 'Authentication required';
  end if;

  select
    messages.media_bucket,
    messages.media_path,
    messages.encryption_version
  into stored_bucket, stored_path, target_encryption_version
  from public.messages
  where id = target_message_id
    and sender_id = active_user_id
    and deleted_at is null
    and message_type <> 'call'
    and public.is_conversation_member(conversation_id, active_user_id)
    and public.is_conversation_member(
      conversation_id,
      active_user_id,
      created_at
    )
  for update;

  if not found then
    raise exception 'Message is missing or cannot be deleted';
  end if;
  if target_encryption_version <> 1 then
    raise exception 'Legacy messages are read-only and cannot be deleted';
  end if;

  delete from public.message_reactions where message_id = target_message_id;
  delete from public.encrypted_message_reactions where message_id = target_message_id;

  update public.messages
  set body = '',
      message_type = 'text',
      media_bucket = null,
      media_path = null,
      media_mime_type = null,
      media_size_bytes = null,
      media_width = null,
      media_height = null,
      media_duration_ms = null,
      media_waveform = null,
      media_original_name = null,
      reply_to_message_id = null,
      e2ee_epoch_id = null,
      e2ee_epoch_number = null,
      e2ee_sender_device_id = null,
      e2ee_ciphertext = null,
      e2ee_nonce = null,
      e2ee_signature = null,
      e2ee_aad_version = null,
      latest_revision_id = null,
      deleted_at = now()
  where id = target_message_id;

  delete from public.message_revisions
  where message_id = target_message_id;

  return query select stored_bucket, stored_path;
end;
$$;

create or replace function public.toggle_message_reaction(
  target_message_id uuid,
  selected_emoji text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  active_user_id uuid := auth.uid();
  target_conversation_id uuid;
  target_encryption_version integer;
  normalized_emoji text := trim(selected_emoji);
begin
  if active_user_id is null then
    raise exception 'Authentication required';
  end if;
  if normalized_emoji is null
    or char_length(normalized_emoji) not between 1 and 32 then
    raise exception 'Choose one valid emoji';
  end if;

  select conversation_id, encryption_version
  into target_conversation_id, target_encryption_version
  from public.messages
  where id = target_message_id
    and deleted_at is null
    and public.is_conversation_member(conversation_id, active_user_id)
    and public.is_conversation_member(
      conversation_id,
      active_user_id,
      created_at
    );

  if target_conversation_id is null then
    raise exception 'Message is missing or cannot be reacted to';
  end if;
  raise exception 'Legacy messages are read-only; encrypted messages use set_encrypted_reaction';
end;
$$;

create or replace function public.set_e2ee_plaintext_cutover(
  p_plaintext_cutover_at timestamptz default now()
)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.e2ee_rollout_config (
    id, plaintext_cutover_at, updated_at
  )
  values (
    true, p_plaintext_cutover_at, now()
  )
  on conflict (id) do update
  set plaintext_cutover_at = excluded.plaintext_cutover_at,
      updated_at = now();

  return p_plaintext_cutover_at;
end;
$$;

create or replace function public.enqueue_push_notification_after_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  conversation_record public.conversations;
begin
  select *
  into conversation_record
  from public.conversations
  where id = new.conversation_id;

  insert into public.push_notification_jobs (
    message_id,
    conversation_id,
    recipient_id,
    sender_id,
    title,
    body,
    data
  )
  select
    new.id,
    new.conversation_id,
    members.user_id,
    new.sender_id,
    'New message',
    'Open ChatApp to read it',
    jsonb_build_object(
      'type', 'message',
      'message_id', new.id,
      'conversation_id', new.conversation_id,
      'sender_id', new.sender_id,
      'conversation_type', conversation_record.conversation_type,
      'encryption_version', new.encryption_version
    )
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

-- Call media is out of scope for E2EE v1, but call-history rows must not
-- carry descriptive plaintext. The structured event fields remain routable.
alter table public.messages
  add column if not exists call_session_id uuid
    references public.call_sessions (id) on delete set null;

create index if not exists messages_call_session_id_idx
  on public.messages (call_session_id)
  where call_session_id is not null;

create or replace function public.log_call_started_message()
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
    call_session_id,
    call_event,
    created_at
  )
  values (
    new.conversation_id,
    new.caller_id,
    '',
    '',
    'call',
    new.id,
    'started',
    new.created_at
  );
  return new;
end;
$$;

create or replace function public.log_call_finished_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_id uuid;
  actor_name text;
begin
  if old.status in ('ended', 'rejected', 'failed')
      or new.status not in ('ended', 'rejected', 'failed') then
    return new;
  end if;

  actor_id := coalesce(new.ended_by_id, new.caller_id);
  select profiles.display_name
  into actor_name
  from public.profiles
  where profiles.id = actor_id;
  actor_name := coalesce(nullif(actor_name, ''), new.caller_name, 'Someone');

  insert into public.messages (
    conversation_id,
    sender_id,
    sender_name,
    body,
    message_type,
    call_session_id,
    call_event,
    created_at
  )
  values (
    new.conversation_id,
    actor_id,
    '',
    '',
    'call',
    new.id,
    case when new.status = 'ended' then 'ended' else 'failed' end,
    coalesce(new.ended_at, now())
  );
  return new;
end;
$$;

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
  )
  values (
    new.conversation_id,
    new.started_by,
    '',
    '',
    'call',
    new.id,
    'started',
    new.created_at
  );
  return new;
end;
$$;

create or replace function public.log_group_call_finished_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_id uuid := coalesce(new.ended_by_id, new.started_by);
  actor_name text := coalesce(nullif(new.started_by_name, ''), 'Someone');
begin
  if old.status <> 'active' or new.status = 'active' then
    return new;
  end if;

  select coalesce(nullif(trim(display_name), ''), actor_name)
  into actor_name
  from public.profiles
  where id = actor_id;
  actor_name := coalesce(actor_name, nullif(new.started_by_name, ''), 'Someone');

  insert into public.messages (
    conversation_id,
    sender_id,
    sender_name,
    body,
    message_type,
    group_call_session_id,
    call_event,
    created_at
  )
  values (
    new.conversation_id,
    actor_id,
    '',
    '',
    'call',
    new.id,
    case when new.status = 'failed' then 'failed' else 'ended' end,
    coalesce(new.ended_at, now())
  );
  return new;
end;
$$;

drop function if exists public.get_conversation_summaries();

create function public.get_conversation_summaries()
returns table (
  conversation_id uuid,
  latest_message_id uuid,
  latest_message_sender_id uuid,
  latest_message_sender_name text,
  latest_message_body text,
  latest_message_type text,
  latest_message_reply_to_message_id uuid,
  latest_message_call_event text,
  latest_message_deleted_at timestamptz,
  latest_message_at timestamptz,
  latest_message_encryption_version integer,
  latest_message_encryption_state text,
  latest_message_epoch_id uuid,
  latest_message_epoch_number integer,
  latest_message_revision integer,
  latest_message_ciphertext text,
  latest_message_nonce text,
  latest_message_signature text,
  latest_message_sender_device_id uuid,
  latest_message_aad_version smallint,
  unread_count bigint,
  latest_outgoing_message_id uuid,
  latest_outgoing_at timestamptz,
  latest_outgoing_status text,
  status text
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    conversation.id as conversation_id,
    latest_message.id as latest_message_id,
    latest_message.sender_id as latest_message_sender_id,
    latest_message.sender_name as latest_message_sender_name,
    latest_message.body as latest_message_body,
    latest_message.message_type as latest_message_type,
    latest_message.reply_to_message_id as latest_message_reply_to_message_id,
    latest_message.call_event as latest_message_call_event,
    latest_message.deleted_at as latest_message_deleted_at,
    latest_message.created_at as latest_message_at,
    coalesce(latest_message.encryption_version, 0) as latest_message_encryption_version,
    coalesce(latest_message.encryption_state, 'legacy') as latest_message_encryption_state,
    latest_message.e2ee_epoch_id as latest_message_epoch_id,
    latest_message.e2ee_epoch_number as latest_message_epoch_number,
    latest_message.e2ee_revision as latest_message_revision,
    latest_message.e2ee_ciphertext as latest_message_ciphertext,
    latest_message.e2ee_nonce as latest_message_nonce,
    latest_message.e2ee_signature as latest_message_signature,
    latest_message.e2ee_sender_device_id as latest_message_sender_device_id,
    latest_message.e2ee_aad_version as latest_message_aad_version,
    coalesce(unread.unread_count, 0::bigint) as unread_count,
    latest_outgoing.id as latest_outgoing_message_id,
    latest_outgoing.created_at as latest_outgoing_at,
    latest_outgoing.status as latest_outgoing_status,
    case
      when coalesce(unread.unread_count, 0::bigint) > 0 then 'unread'
      else coalesce(latest_outgoing.status, 'none')
    end as status
  from public.conversations as conversation
  left join lateral (
    select
      message.id,
      message.sender_id,
      message.sender_name,
      message.body,
      message.message_type,
      message.reply_to_message_id,
      message.call_event,
      message.deleted_at,
      message.created_at,
      message.encryption_version,
      message.encryption_state,
      message.e2ee_epoch_id,
      message.e2ee_epoch_number,
      message.e2ee_revision,
      message.e2ee_ciphertext,
      message.e2ee_nonce,
      message.e2ee_signature,
      message.e2ee_sender_device_id,
      message.e2ee_aad_version
    from public.messages as message
    where message.conversation_id = conversation.id
      and public.is_conversation_member(
        message.conversation_id,
        auth.uid(),
        message.created_at
      )
    order by message.created_at desc, message.id desc
    limit 1
  ) as latest_message on true
  left join lateral (
    select count(*)::bigint as unread_count
    from public.message_receipts as receipt
    join public.messages as message
      on message.id = receipt.message_id
    where receipt.conversation_id = conversation.id
      and receipt.user_id = auth.uid()
      and receipt.read_at is null
      and message.sender_id <> auth.uid()
      and public.is_conversation_member(
        message.conversation_id,
        auth.uid(),
        message.created_at
      )
  ) as unread on true
  left join lateral (
    select
      message.id,
      message.created_at,
      case
        when not exists (
          select 1
          from public.message_receipts as receipt
          where receipt.message_id = message.id
        )
        or exists (
          select 1
          from public.message_receipts as receipt
          where receipt.message_id = message.id
            and coalesce(receipt.delivered_at, receipt.read_at) is null
        ) then 'sent'
        when exists (
          select 1
          from public.message_receipts as receipt
          where receipt.message_id = message.id
            and receipt.read_at is null
        ) then 'delivered'
        else 'read'
      end as status
    from public.messages as message
    where message.conversation_id = conversation.id
      and message.sender_id = auth.uid()
      and public.is_conversation_member(
        message.conversation_id,
        auth.uid(),
        message.created_at
      )
    order by message.created_at desc, message.id desc
    limit 1
  ) as latest_outgoing on true
  where auth.uid() is not null
    and public.is_conversation_member(conversation.id, auth.uid())
  order by coalesce(
    latest_message.created_at,
    conversation.last_message_at,
    conversation.created_at
  ) desc, conversation.id;
$$;

revoke all on function public.assert_e2ee_encoded_value(text, text, integer, integer)
  from public, anon, authenticated;
revoke all on function public.ensure_conversation_crypto_state()
  from public, anon, authenticated;
revoke all on function public.mark_conversation_membership_rekey()
  from public, anon, authenticated;
revoke all on function public.mark_e2ee_rekey_for_user(uuid)
  from public, anon, authenticated;
revoke all on function public.enforce_e2ee_plaintext_cutover()
  from public, anon, authenticated;

revoke all on function public.register_e2ee_account(text, text, integer)
  from public, anon;
revoke all on function public.register_e2ee_device(
  uuid, text, text, text, text, integer
) from public, anon, authenticated, service_role;
revoke all on function public.register_verified_e2ee_device(
  uuid, uuid, text, text, text, text, integer
) from public, anon, authenticated;
revoke all on function public.revoke_e2ee_device(uuid)
  from public, anon;
revoke all on function public.get_conversation_e2ee_key_material(uuid)
  from public, anon;
revoke all on function public.get_e2ee_device_envelopes(uuid)
  from public, anon;
revoke all on function public.get_e2ee_recovery_envelopes()
  from public, anon;
revoke all on function public.get_conversation_e2ee_device_identities(
  uuid, uuid[]
) from public, anon;
revoke all on function public.publish_conversation_epoch(
  uuid, uuid, integer, integer, uuid, text, text, jsonb
) from public, anon;
revoke all on function public.send_encrypted_message(
  uuid, uuid, uuid, text, text, text, text, text, text, uuid
) from public, anon;
revoke all on function public.edit_encrypted_message(
  uuid, uuid, uuid, integer, text, text, text
) from public, anon;
revoke all on function public.set_encrypted_reaction(
  uuid, uuid, uuid, text, boolean, text, text, text
) from public, anon;

grant execute on function public.register_e2ee_account(text, text, integer)
  to authenticated;
grant execute on function public.register_verified_e2ee_device(
  uuid, uuid, text, text, text, text, integer
) to service_role;
grant execute on function public.revoke_e2ee_device(uuid)
  to authenticated;
grant execute on function public.get_conversation_e2ee_key_material(uuid)
  to authenticated;
grant execute on function public.get_e2ee_device_envelopes(uuid)
  to authenticated;
grant execute on function public.get_e2ee_recovery_envelopes()
  to authenticated;
grant execute on function public.get_conversation_e2ee_device_identities(
  uuid, uuid[]
) to authenticated;
grant execute on function public.publish_conversation_epoch(
  uuid, uuid, integer, integer, uuid, text, text, jsonb
) to authenticated;
grant execute on function public.send_encrypted_message(
  uuid, uuid, uuid, text, text, text, text, text, text, uuid
) to authenticated;
grant execute on function public.edit_encrypted_message(
  uuid, uuid, uuid, integer, text, text, text
) to authenticated;
grant execute on function public.set_encrypted_reaction(
  uuid, uuid, uuid, text, boolean, text, text, text
) to authenticated;

revoke all on function public.set_e2ee_plaintext_cutover(timestamptz)
  from public, anon, authenticated;
grant execute on function public.set_e2ee_plaintext_cutover(timestamptz)
  to service_role;

revoke all on function public.get_conversation_summaries() from public;
grant execute on function public.get_conversation_summaries() to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'conversation_crypto_state'
  ) then
    alter publication supabase_realtime
      add table public.conversation_crypto_state;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'conversation_key_epochs'
  ) then
    alter publication supabase_realtime
      add table public.conversation_key_epochs;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'message_revisions'
  ) then
    alter publication supabase_realtime
      add table public.message_revisions;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'encrypted_message_reactions'
  ) then
    alter publication supabase_realtime
      add table public.encrypted_message_reactions;
  end if;
end;
$$;

notify pgrst, 'reload schema';
