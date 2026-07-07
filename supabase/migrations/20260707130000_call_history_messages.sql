alter table public.call_sessions
  add column if not exists ended_by_id uuid references auth.users (id) on delete set null;

alter table public.messages
  drop constraint if exists messages_message_type_check,
  add constraint messages_message_type_check
  check (message_type in ('text', 'image', 'gif', 'voice', 'call'));

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
    created_at
  )
  values (
    new.conversation_id,
    new.caller_id,
    new.caller_name,
    new.caller_name || ' started a ' ||
      case when new.is_video then 'video call' else 'voice call' end,
    'call',
    new.created_at
  );

  return new;
end;
$$;

drop trigger if exists on_call_session_started_message on public.call_sessions;
create trigger on_call_session_started_message
  after insert on public.call_sessions
  for each row execute function public.log_call_started_message();

create or replace function public.log_call_finished_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_id uuid;
  actor_name text;
  event_body text;
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

  event_body := case new.status
    when 'rejected' then actor_name || ' declined the call'
    when 'failed' then 'Call failed'
    else actor_name || ' ended the call'
  end;

  insert into public.messages (
    conversation_id,
    sender_id,
    sender_name,
    body,
    message_type,
    created_at
  )
  values (
    new.conversation_id,
    actor_id,
    actor_name,
    event_body,
    'call',
    coalesce(new.ended_at, now())
  );

  return new;
end;
$$;

drop trigger if exists on_call_session_finished_message on public.call_sessions;
create trigger on_call_session_finished_message
  after update of status on public.call_sessions
  for each row execute function public.log_call_finished_message();
