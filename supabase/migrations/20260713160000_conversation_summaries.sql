create index if not exists messages_conversation_latest_idx
  on public.messages (conversation_id, created_at desc, id desc);

create index if not exists messages_conversation_sender_latest_idx
  on public.messages (conversation_id, sender_id, created_at desc, id desc);

create index if not exists message_receipts_user_unread_conversation_idx
  on public.message_receipts (user_id, conversation_id, message_id)
  where read_at is null;

create or replace function public.get_conversation_summaries()
returns table (
  conversation_id uuid,
  latest_message_id uuid,
  latest_message_sender_id uuid,
  latest_message_sender_name text,
  latest_message_body text,
  latest_message_type text,
  latest_message_deleted_at timestamptz,
  latest_message_at timestamptz,
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
    latest_message.deleted_at as latest_message_deleted_at,
    latest_message.created_at as latest_message_at,
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
      message.deleted_at,
      message.created_at
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

revoke all on function public.get_conversation_summaries() from public;
grant execute on function public.get_conversation_summaries() to authenticated;

notify pgrst, 'reload schema';
