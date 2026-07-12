alter table public.messages
  add column if not exists reply_to_message_id uuid,
  add column if not exists is_forwarded boolean not null default false,
  add column if not exists edited_at timestamptz,
  add column if not exists deleted_at timestamptz;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.messages'::regclass
      and conname = 'messages_reply_to_message_id_fkey'
  ) then
    alter table public.messages
      add constraint messages_reply_to_message_id_fkey
      foreign key (reply_to_message_id)
      references public.messages (id)
      on delete set null;
  end if;
end $$;

create index if not exists messages_reply_to_message_id_idx
  on public.messages (reply_to_message_id)
  where reply_to_message_id is not null;

create table if not exists public.message_reactions (
  message_id uuid not null references public.messages (id) on delete cascade,
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  emoji text not null check (char_length(emoji) between 1 and 32),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id, emoji)
);

create index if not exists message_reactions_conversation_idx
  on public.message_reactions (conversation_id, message_id);

create or replace function public.validate_message_reply()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  replied_conversation_id uuid;
  replied_deleted_at timestamptz;
begin
  if new.reply_to_message_id is null then
    return new;
  end if;

  if new.reply_to_message_id = new.id then
    raise exception 'A message cannot reply to itself';
  end if;

  select source.conversation_id, source.deleted_at
  into replied_conversation_id, replied_deleted_at
  from public.messages as source
  where source.id = new.reply_to_message_id;

  if replied_conversation_id is null then
    raise exception 'Reply target does not exist';
  end if;
  if replied_conversation_id <> new.conversation_id then
    raise exception 'Reply target must belong to the same conversation';
  end if;
  if replied_deleted_at is not null then
    raise exception 'Cannot reply to a deleted message';
  end if;

  return new;
end;
$$;

drop trigger if exists on_message_validate_reply on public.messages;
create trigger on_message_validate_reply
  before insert or update of reply_to_message_id, conversation_id
  on public.messages
  for each row execute function public.validate_message_reply();

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
begin
  if active_user_id is null then
    raise exception 'Authentication required';
  end if;

  select message_type
  into target_type
  from public.messages
  where id = target_message_id
    and sender_id = active_user_id
    and deleted_at is null
    and exists (
      select 1 from public.conversations
      where conversations.id = messages.conversation_id
        and active_user_id in (conversations.user_one_id, conversations.user_two_id)
    )
  for update;

  if not found then
    raise exception 'Message is missing or cannot be edited';
  end if;
  if target_type = 'call' then
    raise exception 'Call events cannot be edited';
  end if;
  if target_type = 'text' and nullif(trim(coalesce(new_body, '')), '') is null then
    raise exception 'Text messages cannot be empty';
  end if;

  update public.messages
  set body = trim(coalesce(new_body, '')),
      edited_at = now()
  where id = target_message_id;
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
begin
  if active_user_id is null then
    raise exception 'Authentication required';
  end if;

  select messages.media_bucket, messages.media_path
  into stored_bucket, stored_path
  from public.messages
  where id = target_message_id
    and sender_id = active_user_id
    and deleted_at is null
    and message_type <> 'call'
    and exists (
      select 1 from public.conversations
      where conversations.id = messages.conversation_id
        and active_user_id in (conversations.user_one_id, conversations.user_two_id)
    )
  for update;

  if not found then
    raise exception 'Message is missing or cannot be deleted';
  end if;

  delete from public.message_reactions
  where message_id = target_message_id;

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
      deleted_at = now()
  where id = target_message_id;

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
  normalized_emoji text := trim(selected_emoji);
begin
  if active_user_id is null then
    raise exception 'Authentication required';
  end if;
  if normalized_emoji is null
    or char_length(normalized_emoji) not between 1 and 32 then
    raise exception 'Choose one valid emoji';
  end if;

  select messages.conversation_id
  into target_conversation_id
  from public.messages
  join public.conversations
    on conversations.id = messages.conversation_id
  where messages.id = target_message_id
    and messages.deleted_at is null
    and active_user_id in (conversations.user_one_id, conversations.user_two_id);

  if target_conversation_id is null then
    raise exception 'Message is missing or cannot be reacted to';
  end if;

  if exists (
    select 1
    from public.message_reactions
    where message_id = target_message_id
      and user_id = active_user_id
      and emoji = normalized_emoji
  ) then
    delete from public.message_reactions
    where message_id = target_message_id
      and user_id = active_user_id
      and emoji = normalized_emoji;
    return false;
  end if;

  insert into public.message_reactions (
    message_id,
    conversation_id,
    user_id,
    emoji
  ) values (
    target_message_id,
    target_conversation_id,
    active_user_id,
    normalized_emoji
  )
  on conflict (message_id, user_id, emoji) do nothing;
  return true;
end;
$$;

alter table public.message_reactions enable row level security;
grant select on table public.message_reactions to authenticated;

drop policy if exists "Conversation members can read message reactions"
  on public.message_reactions;
create policy "Conversation members can read message reactions"
  on public.message_reactions
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.conversations
      where conversations.id = message_reactions.conversation_id
        and auth.uid() in (conversations.user_one_id, conversations.user_two_id)
    )
  );

revoke all on function public.edit_message(uuid, text) from public;
revoke all on function public.delete_message(uuid) from public;
revoke all on function public.toggle_message_reaction(uuid, text) from public;
grant execute on function public.edit_message(uuid, text) to authenticated;
grant execute on function public.delete_message(uuid) to authenticated;
grant execute on function public.toggle_message_reaction(uuid, text) to authenticated;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'message_reactions'
  ) then
    alter publication supabase_realtime add table public.message_reactions;
  end if;
end $$;

notify pgrst, 'reload schema';
