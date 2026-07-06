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
    'image/heif',
    'audio/wav',
    'audio/x-wav',
    'audio/aac',
    'audio/mpeg',
    'audio/mp3',
    'audio/mp4',
    'audio/webm',
    'audio/ogg'
  ]::text[]
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

alter table public.messages
  add column if not exists media_duration_ms integer,
  add column if not exists media_waveform jsonb;

alter table public.messages
  drop constraint if exists messages_message_type_check,
  add constraint messages_message_type_check
  check (message_type in ('text', 'image', 'gif', 'voice'));

alter table public.messages
  drop constraint if exists messages_media_payload_check,
  add constraint messages_media_payload_check
  check (
    (
      message_type = 'text'
      and media_bucket is null
      and media_path is null
      and media_mime_type is null
      and media_size_bytes is null
      and media_width is null
      and media_height is null
      and media_duration_ms is null
      and media_waveform is null
    )
    or (
      message_type in ('image', 'gif')
      and media_bucket = 'chat-media'
      and media_path is not null
      and media_mime_type like 'image/%'
      and media_size_bytes between 1 and 15728640
      and media_duration_ms is null
      and media_waveform is null
    )
    or (
      message_type = 'voice'
      and media_bucket = 'chat-media'
      and media_path is not null
      and media_mime_type like 'audio/%'
      and media_size_bytes between 1 and 15728640
      and (media_duration_ms is null or media_duration_ms between 0 and 3600000)
      and (media_waveform is null or jsonb_typeof(media_waveform) = 'array')
    )
  );

notify pgrst, 'reload schema';
