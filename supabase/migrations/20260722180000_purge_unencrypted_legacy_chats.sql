-- Purge all unencrypted legacy chats and messages (encryption_version = 0)
delete from public.message_reactions
where message_id in (
  select id from public.messages where encryption_version <> 1
);

delete from public.messages
where encryption_version <> 1;

delete from public.conversations
where id not in (
  select distinct conversation_id from public.messages where encryption_version = 1
);

-- Restrict new messages to E2E encrypted only (encryption_version = 1)
alter table public.messages
  drop constraint if exists messages_encryption_version_check,
  add constraint messages_encryption_version_check
    check (encryption_version = 1);
