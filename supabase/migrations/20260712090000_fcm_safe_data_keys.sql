create or replace function public.enqueue_push_notification_after_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  target_recipient_id uuid;
  notification_body text;
begin
  select
    case
      when conversations.user_one_id = new.sender_id then conversations.user_two_id
      else conversations.user_one_id
    end
  into target_recipient_id
  from public.conversations
  where conversations.id = new.conversation_id
    and new.sender_id in (conversations.user_one_id, conversations.user_two_id);

  if target_recipient_id is null or target_recipient_id = new.sender_id then
    return new;
  end if;

  notification_body := public.push_message_preview(
    coalesce(new.message_type, 'text'),
    new.body
  );

  insert into public.push_notification_jobs (
    message_id,
    conversation_id,
    recipient_id,
    sender_id,
    title,
    body,
    data
  )
  values (
    new.id,
    new.conversation_id,
    target_recipient_id,
    new.sender_id,
    new.sender_name,
    notification_body,
    jsonb_build_object(
      'type', 'message',
      'message_id', new.id,
      'conversation_id', new.conversation_id,
      'sender_id', new.sender_id,
      'chat_message_type', coalesce(new.message_type, 'text')
    )
  )
  on conflict on constraint push_notification_jobs_message_recipient_key
    do nothing;

  perform public.invoke_push_notification_dispatch();
  return new;
end;
$$;

notify pgrst, 'reload schema';
