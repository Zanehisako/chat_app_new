alter table public.conversations
  add column if not exists conversation_type text not null default 'direct',
  add column if not exists title text,
  add column if not exists created_by uuid references auth.users (id) on delete set null;

alter table public.conversations
  alter column user_one_id drop not null,
  alter column user_two_id drop not null,
  drop constraint if exists conversations_distinct_users_check,
  drop constraint if exists conversations_sorted_users_check,
  drop constraint if exists conversations_type_payload_check,
  drop constraint if exists conversations_title_length_check;

alter table public.conversations
  add constraint conversations_type_payload_check check (
    (
      conversation_type = 'direct'
      and user_one_id is not null
      and user_two_id is not null
      and user_one_id <> user_two_id
      and user_one_id < user_two_id
    )
    or (
      conversation_type = 'group'
      and title is not null
      and user_one_id is null
      and user_two_id is null
      and created_by is not null
    )
  ),
  add constraint conversations_title_length_check check (
    conversation_type = 'direct'
    or char_length(trim(title)) between 1 and 80
  );

create table if not exists public.conversation_members (
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null default 'member' check (role in ('admin', 'member')),
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  primary key (conversation_id, user_id),
  constraint conversation_members_period_check check (
    left_at is null or left_at >= joined_at
  )
);

create index if not exists conversation_members_user_active_idx
  on public.conversation_members (user_id, conversation_id)
  where left_at is null;

insert into public.conversation_members (conversation_id, user_id, role, joined_at)
select id, user_one_id, 'member', created_at
from public.conversations
where conversation_type = 'direct' and user_one_id is not null
on conflict (conversation_id, user_id) do nothing;

insert into public.conversation_members (conversation_id, user_id, role, joined_at)
select id, user_two_id, 'member', created_at
from public.conversations
where conversation_type = 'direct' and user_two_id is not null
on conflict (conversation_id, user_id) do nothing;

create or replace function public.is_conversation_member(
  target_conversation_id uuid,
  target_user_id uuid default auth.uid(),
  at_time timestamptz default now()
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.conversation_members
    where conversation_id = target_conversation_id
      and user_id = target_user_id
      and joined_at <= at_time
      and (left_at is null or left_at > at_time)
  );
$$;

create or replace function public.is_group_admin(
  target_conversation_id uuid,
  target_user_id uuid default auth.uid()
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.conversation_members
    join public.conversations
      on conversations.id = conversation_members.conversation_id
    where conversation_members.conversation_id = target_conversation_id
      and conversation_members.user_id = target_user_id
      and conversation_members.role = 'admin'
      and conversation_members.left_at is null
      and conversations.conversation_type = 'group'
  );
$$;

create or replace function public.sync_direct_conversation_members()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.conversation_type = 'direct' then
    insert into public.conversation_members (
      conversation_id, user_id, role, joined_at
    ) values
      (new.id, new.user_one_id, 'member', new.created_at),
      (new.id, new.user_two_id, 'member', new.created_at)
    on conflict (conversation_id, user_id) do update
      set left_at = null;
  end if;
  return new;
end;
$$;

drop trigger if exists on_direct_conversation_sync_members
  on public.conversations;
create trigger on_direct_conversation_sync_members
  after insert on public.conversations
  for each row execute function public.sync_direct_conversation_members();

create or replace function public.create_group_conversation(
  group_name text,
  member_ids uuid[]
)
returns public.conversations
language plpgsql
security definer
set search_path = public
as $$
declare
  active_user_id uuid := auth.uid();
  normalized_name text := trim(group_name);
  normalized_members uuid[];
  created_conversation public.conversations;
begin
  if active_user_id is null then
    raise exception 'Authentication required';
  end if;
  if char_length(normalized_name) not between 1 and 80 then
    raise exception 'Group names must be between 1 and 80 characters';
  end if;

  select coalesce(array_agg(distinct member_id), '{}'::uuid[])
  into normalized_members
  from unnest(coalesce(member_ids, '{}'::uuid[])) as selected(member_id)
  where member_id <> active_user_id;

  if cardinality(normalized_members) < 2 then
    raise exception 'Choose at least two other group members';
  end if;
  if cardinality(normalized_members) > 49 then
    raise exception 'Groups can have at most 50 members';
  end if;
  if (
    select count(*) from public.profiles
    where id = any(normalized_members)
  ) <> cardinality(normalized_members) then
    raise exception 'One or more selected members do not exist';
  end if;

  insert into public.conversations (
    conversation_type, title, created_by
  ) values (
    'group', normalized_name, active_user_id
  ) returning * into created_conversation;

  insert into public.conversation_members (
    conversation_id, user_id, role
  ) values (
    created_conversation.id, active_user_id, 'admin'
  );

  insert into public.conversation_members (
    conversation_id, user_id, role
  )
  select created_conversation.id, member_id, 'member'
  from unnest(normalized_members) as selected(member_id);

  return created_conversation;
end;
$$;

create or replace function public.rename_group_conversation(
  target_conversation_id uuid,
  new_name text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  normalized_name text := trim(new_name);
begin
  if not public.is_group_admin(target_conversation_id, auth.uid()) then
    raise exception 'Only group admins can rename this group';
  end if;
  if char_length(normalized_name) not between 1 and 80 then
    raise exception 'Group names must be between 1 and 80 characters';
  end if;

  update public.conversations
  set title = normalized_name, updated_at = now()
  where id = target_conversation_id and conversation_type = 'group';
end;
$$;

create or replace function public.add_group_member(
  target_conversation_id uuid,
  new_member_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_group_admin(target_conversation_id, auth.uid()) then
    raise exception 'Only group admins can add members';
  end if;
  if not exists (select 1 from public.profiles where id = new_member_id) then
    raise exception 'That user does not exist';
  end if;
  if public.is_conversation_member(target_conversation_id, new_member_id) then
    raise exception 'That user is already a member';
  end if;
  if (
    select count(*) from public.conversation_members
    where conversation_id = target_conversation_id and left_at is null
  ) >= 50 then
    raise exception 'Groups can have at most 50 members';
  end if;

  insert into public.conversation_members (
    conversation_id, user_id, role, joined_at, left_at
  ) values (
    target_conversation_id, new_member_id, 'member', now(), null
  )
  on conflict (conversation_id, user_id) do update
    set role = 'member', joined_at = now(), left_at = null;

  update public.conversations
  set updated_at = now()
  where id = target_conversation_id;
end;
$$;

create or replace function public.remove_group_member(
  target_conversation_id uuid,
  removed_member_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_group_admin(target_conversation_id, auth.uid()) then
    raise exception 'Only group admins can remove members';
  end if;
  if removed_member_id = auth.uid() then
    raise exception 'Use leave_group_conversation to leave the group';
  end if;

  update public.conversation_members
  set left_at = now()
  where conversation_id = target_conversation_id
    and user_id = removed_member_id
    and left_at is null;
  if not found then
    raise exception 'That user is not an active member';
  end if;

  update public.conversations
  set updated_at = now()
  where id = target_conversation_id;
end;
$$;

create or replace function public.leave_group_conversation(
  target_conversation_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  active_user_id uuid := auth.uid();
  leaving_role text;
  promoted_user_id uuid;
begin
  select role into leaving_role
  from public.conversation_members
  where conversation_id = target_conversation_id
    and user_id = active_user_id
    and left_at is null
  for update;

  if leaving_role is null then
    raise exception 'You are not an active group member';
  end if;
  if not exists (
    select 1 from public.conversations
    where id = target_conversation_id and conversation_type = 'group'
  ) then
    raise exception 'Only groups can be left';
  end if;

  if leaving_role = 'admin' and not exists (
    select 1 from public.conversation_members
    where conversation_id = target_conversation_id
      and user_id <> active_user_id
      and role = 'admin'
      and left_at is null
  ) then
    select user_id into promoted_user_id
    from public.conversation_members
    where conversation_id = target_conversation_id
      and user_id <> active_user_id
      and left_at is null
    order by joined_at, user_id
    limit 1;

    if promoted_user_id is not null then
      update public.conversation_members
      set role = 'admin'
      where conversation_id = target_conversation_id
        and user_id = promoted_user_id;
    end if;
  end if;

  update public.conversation_members
  set left_at = now()
  where conversation_id = target_conversation_id
    and user_id = active_user_id;

  update public.conversations
  set updated_at = now()
  where id = target_conversation_id;
end;
$$;

alter table public.conversation_members enable row level security;
grant select on table public.conversation_members to authenticated;

drop policy if exists "Active members can read group membership"
  on public.conversation_members;
create policy "Active members can read group membership"
  on public.conversation_members
  for select
  to authenticated
  using (
    left_at is null
    and public.is_conversation_member(conversation_id, auth.uid())
  );

drop policy if exists "Users can read own conversations"
  on public.conversations;
create policy "Users can read own conversations"
  on public.conversations
  for select
  to authenticated
  using (public.is_conversation_member(id, auth.uid()));

drop policy if exists "Users can create own direct conversations"
  on public.conversations;
create policy "Users can create own direct conversations"
  on public.conversations
  for insert
  to authenticated
  with check (
    conversation_type = 'direct'
    and auth.uid() in (user_one_id, user_two_id)
  );

drop policy if exists "Users can read own conversation messages"
  on public.messages;
create policy "Users can read own conversation messages"
  on public.messages
  for select
  to authenticated
  using (
    public.is_conversation_member(conversation_id, auth.uid())
    and public.is_conversation_member(conversation_id, auth.uid(), created_at)
  );

drop policy if exists "Users can send own conversation messages"
  on public.messages;
create policy "Users can send own conversation messages"
  on public.messages
  for insert
  to authenticated
  with check (
    sender_id = auth.uid()
    and public.is_conversation_member(conversation_id, auth.uid())
    and public.is_conversation_member(conversation_id, auth.uid(), created_at)
  );

drop policy if exists "Conversation members can read chat media"
  on storage.objects;
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
    and exists (
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
  );

drop policy if exists "Conversation senders can upload chat media"
  on storage.objects;
create policy "Conversation senders can upload chat media"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'chat-media'
    and (storage.foldername(name))[2] = auth.uid()::text
    and public.is_conversation_member(
      ((storage.foldername(name))[1])::uuid,
      auth.uid()
    )
  );

drop policy if exists "Conversation senders can delete chat media"
  on storage.objects;
create policy "Conversation senders can delete chat media"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'chat-media'
    and (storage.foldername(name))[2] = auth.uid()::text
    and public.is_conversation_member(
      ((storage.foldername(name))[1])::uuid,
      auth.uid()
    )
  );

drop policy if exists "Users can read own conversation receipts"
  on public.message_receipts;
create policy "Users can read own conversation receipts"
  on public.message_receipts
  for select
  to authenticated
  using (
    public.is_conversation_member(conversation_id, auth.uid())
    and exists (
      select 1 from public.messages
      where messages.id = message_receipts.message_id
        and public.is_conversation_member(
          messages.conversation_id,
          auth.uid(),
          messages.created_at
        )
    )
  );

drop policy if exists "Users can update their own receipts"
  on public.message_receipts;
create policy "Users can update their own receipts"
  on public.message_receipts
  for update
  to authenticated
  using (
    user_id = auth.uid()
    and public.is_conversation_member(conversation_id, auth.uid())
  )
  with check (
    user_id = auth.uid()
    and public.is_conversation_member(conversation_id, auth.uid())
  );

create or replace function public.create_receipt_after_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.message_receipts (
    message_id, conversation_id, user_id
  )
  select new.id, new.conversation_id, members.user_id
  from public.conversation_members as members
  where members.conversation_id = new.conversation_id
    and members.user_id <> new.sender_id
    and members.left_at is null
    and members.joined_at <= new.created_at
  on conflict (message_id, user_id) do nothing;
  return new;
end;
$$;

drop policy if exists "Conversation members can read message reactions"
  on public.message_reactions;
create policy "Conversation members can read message reactions"
  on public.message_reactions
  for select
  to authenticated
  using (
    public.is_conversation_member(conversation_id, auth.uid())
    and exists (
      select 1 from public.messages
      where messages.id = message_reactions.message_id
        and public.is_conversation_member(
          messages.conversation_id,
          auth.uid(),
          messages.created_at
        )
    )
  );

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
  if active_user_id is null then raise exception 'Authentication required'; end if;

  select message_type into target_type
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

  if not found then raise exception 'Message is missing or cannot be edited'; end if;
  if target_type = 'call' then raise exception 'Call events cannot be edited'; end if;
  if target_type = 'text' and nullif(trim(coalesce(new_body, '')), '') is null then
    raise exception 'Text messages cannot be empty';
  end if;

  update public.messages
  set body = trim(coalesce(new_body, '')), edited_at = now()
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
  if active_user_id is null then raise exception 'Authentication required'; end if;

  select messages.media_bucket, messages.media_path
  into stored_bucket, stored_path
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

  if not found then raise exception 'Message is missing or cannot be deleted'; end if;

  delete from public.message_reactions where message_id = target_message_id;
  update public.messages
  set body = '', message_type = 'text', media_bucket = null,
      media_path = null, media_mime_type = null, media_size_bytes = null,
      media_width = null, media_height = null, media_duration_ms = null,
      media_waveform = null, media_original_name = null,
      reply_to_message_id = null, deleted_at = now()
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
  if active_user_id is null then raise exception 'Authentication required'; end if;
  if normalized_emoji is null or char_length(normalized_emoji) not between 1 and 32 then
    raise exception 'Choose one valid emoji';
  end if;

  select conversation_id into target_conversation_id
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

  if exists (
    select 1 from public.message_reactions
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
    message_id, conversation_id, user_id, emoji
  ) values (
    target_message_id, target_conversation_id, active_user_id, normalized_emoji
  ) on conflict (message_id, user_id, emoji) do nothing;
  return true;
end;
$$;

create or replace function public.enqueue_push_notification_after_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  notification_preview text;
  conversation_record public.conversations;
begin
  select * into conversation_record
  from public.conversations
  where id = new.conversation_id;

  notification_preview := public.push_message_preview(
    coalesce(new.message_type, 'text'), new.body
  );

  insert into public.push_notification_jobs (
    message_id, conversation_id, recipient_id, sender_id,
    title, body, data
  )
  select
    new.id,
    new.conversation_id,
    members.user_id,
    new.sender_id,
    case
      when conversation_record.conversation_type = 'group'
        then conversation_record.title
      else new.sender_name
    end,
    case
      when conversation_record.conversation_type = 'group'
        then new.sender_name || ': ' || notification_preview
      else notification_preview
    end,
    jsonb_build_object(
      'type', 'message',
      'message_id', new.id,
      'conversation_id', new.conversation_id,
      'sender_id', new.sender_id,
      'chat_message_type', coalesce(new.message_type, 'text'),
      'conversation_type', conversation_record.conversation_type
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

revoke all on function public.create_group_conversation(text, uuid[]) from public;
revoke all on function public.rename_group_conversation(uuid, text) from public;
revoke all on function public.add_group_member(uuid, uuid) from public;
revoke all on function public.remove_group_member(uuid, uuid) from public;
revoke all on function public.leave_group_conversation(uuid) from public;
grant execute on function public.create_group_conversation(text, uuid[]) to authenticated;
grant execute on function public.rename_group_conversation(uuid, text) to authenticated;
grant execute on function public.add_group_member(uuid, uuid) to authenticated;
grant execute on function public.remove_group_member(uuid, uuid) to authenticated;
grant execute on function public.leave_group_conversation(uuid) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'conversation_members'
  ) then
    alter publication supabase_realtime add table public.conversation_members;
  end if;
end $$;

notify pgrst, 'reload schema';
