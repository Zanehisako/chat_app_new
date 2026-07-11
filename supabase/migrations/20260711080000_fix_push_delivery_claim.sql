create or replace function public.claim_push_notification_deliveries(
  batch_size integer default 25
)
returns table (
  delivery_id uuid,
  lease_id uuid,
  job_id uuid,
  message_id uuid,
  conversation_id uuid,
  recipient_id uuid,
  title text,
  body text,
  data jsonb,
  attempt_count integer,
  token_id uuid,
  provider text,
  token text,
  platform text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  with claimed as (
    select deliveries.id
    from public.push_notification_deliveries as deliveries
    where (
      deliveries.status in ('pending', 'retry')
      and deliveries.next_attempt_at <= now()
    ) or (
      deliveries.status = 'sending'
      and deliveries.lease_expires_at <= now()
    )
    order by deliveries.created_at
    limit least(greatest(coalesce(batch_size, 25), 1), 100)
    for update skip locked
  ),
  updated as (
    update public.push_notification_deliveries as deliveries
    set status = 'sending',
        attempt_count = deliveries.attempt_count + 1,
        last_attempt_at = now(),
        lease_id = gen_random_uuid(),
        lease_expires_at = now() + interval '15 minutes',
        updated_at = now()
    from claimed
    where deliveries.id = claimed.id
    returning
      deliveries.id,
      deliveries.lease_id,
      deliveries.job_id,
      deliveries.attempt_count,
      deliveries.device_token_id
  ),
  touch_jobs as (
    update public.push_notification_jobs as jobs
    set status = 'sending',
        updated_at = now()
    from (select distinct updated.job_id from updated) as touched
    where jobs.id = touched.job_id
    returning jobs.id
  )
  select
    updated.id as delivery_id,
    updated.lease_id,
    jobs.id as job_id,
    jobs.message_id,
    jobs.conversation_id,
    jobs.recipient_id,
    jobs.title,
    jobs.body,
    jobs.data,
    updated.attempt_count,
    tokens.id as token_id,
    tokens.provider,
    tokens.token,
    tokens.platform
  from updated
  join public.push_notification_jobs as jobs on jobs.id = updated.job_id
  left join public.push_device_tokens as tokens
    on tokens.id = updated.device_token_id
    and tokens.user_id = jobs.recipient_id
    and tokens.disabled_at is null
    and (tokens.expires_at is null or tokens.expires_at > now());
end;
$$;

revoke all on function public.claim_push_notification_deliveries(integer)
  from public, anon, authenticated;
grant execute on function public.claim_push_notification_deliveries(integer)
  to service_role;

notify pgrst, 'reload schema';
