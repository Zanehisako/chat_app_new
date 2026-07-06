insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'chat-media',
  'chat-media',
  false,
  15728640,
  array[
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/gif',
    'image/heic',
    'image/heif'
  ]::text[]
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

alter table public.messages
  alter column body drop not null,
  alter column body set default '',
  add column if not exists message_type text not null default 'text',
  add column if not exists media_bucket text,
  add column if not exists media_path text,
  add column if not exists media_mime_type text,
  add column if not exists media_size_bytes bigint,
  add column if not exists media_width integer,
  add column if not exists media_height integer,
  add column if not exists media_original_name text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'messages_message_type_check'
      and conrelid = 'public.messages'::regclass
  ) then
    alter table public.messages
      add constraint messages_message_type_check
      check (message_type in ('text', 'image', 'gif'));
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'messages_media_payload_check'
      and conrelid = 'public.messages'::regclass
  ) then
    alter table public.messages
      add constraint messages_media_payload_check
      check (
        (
          message_type = 'text'
          and media_bucket is null
          and media_path is null
        )
        or (
          message_type in ('image', 'gif')
          and media_bucket = 'chat-media'
          and media_path is not null
          and media_mime_type like 'image/%'
          and media_size_bytes between 1 and 15728640
        )
      );
  end if;
end $$;

create index if not exists messages_media_path_idx
  on public.messages (media_bucket, media_path)
  where media_path is not null;

drop policy if exists "Conversation members can read chat media" on storage.objects;
create policy "Conversation members can read chat media"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'chat-media'
    and exists (
      select 1
      from public.conversations
      where conversations.id::text = (storage.foldername(name))[1]
        and auth.uid() in (conversations.user_one_id, conversations.user_two_id)
    )
  );

drop policy if exists "Conversation senders can upload chat media" on storage.objects;
create policy "Conversation senders can upload chat media"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'chat-media'
    and (storage.foldername(name))[2] = auth.uid()::text
    and exists (
      select 1
      from public.conversations
      where conversations.id::text = (storage.foldername(name))[1]
        and auth.uid() in (conversations.user_one_id, conversations.user_two_id)
    )
  );

drop policy if exists "Conversation senders can delete chat media" on storage.objects;
create policy "Conversation senders can delete chat media"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'chat-media'
    and (storage.foldername(name))[2] = auth.uid()::text
    and exists (
      select 1
      from public.conversations
      where conversations.id::text = (storage.foldername(name))[1]
        and auth.uid() in (conversations.user_one_id, conversations.user_two_id)
    )
  );

notify pgrst, 'reload schema';
