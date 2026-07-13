-- Dispatch LiveKit participant-removal jobs without relying on the
-- self-hosted Docker worker. The configuration row is owner-managed and has
-- no client-facing RLS policy.

create extension if not exists pg_net;
create extension if not exists pg_cron;

create table if not exists public.group_call_control_dispatch_config (
  id boolean primary key default true check (id),
  function_url text,
  dispatch_secret text,
  enabled boolean not null default false,
  updated_at timestamptz not null default now()
);

alter table public.group_call_control_dispatch_config enable row level security;
revoke all on table public.group_call_control_dispatch_config
  from public, anon, authenticated;
grant select, insert, update, delete
  on table public.group_call_control_dispatch_config to service_role;

create or replace function public.invoke_group_call_control_dispatch()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  config public.group_call_control_dispatch_config;
begin
  select * into config
  from public.group_call_control_dispatch_config
  where id = true
    and enabled = true
    and nullif(trim(function_url), '') is not null
    and nullif(dispatch_secret, '') is not null;

  if not found then
    return;
  end if;

  perform net.http_post(
    url := config.function_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-dispatch-secret', config.dispatch_secret
    ),
    body := jsonb_build_object('source', 'database'),
    timeout_milliseconds := 5000
  );
exception
  when others then
    return;
end;
$$;

revoke all on function public.invoke_group_call_control_dispatch()
  from public, anon, authenticated;
grant execute on function public.invoke_group_call_control_dispatch()
  to service_role;

create or replace function public.dispatch_group_call_control_job()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.invoke_group_call_control_dispatch();
  return new;
end;
$$;

revoke all on function public.dispatch_group_call_control_job()
  from public, anon, authenticated;

drop trigger if exists on_group_call_control_job_insert
  on public.group_call_control_jobs;
create trigger on_group_call_control_job_insert
  after insert on public.group_call_control_jobs
  for each row execute function public.dispatch_group_call_control_job();

do $$
declare
  existing_job_id bigint;
begin
  select jobid into existing_job_id
  from cron.job
  where jobname = 'dispatch-group-call-control-retries';

  if existing_job_id is not null then
    perform cron.unschedule(existing_job_id);
  end if;

  perform cron.schedule(
    'dispatch-group-call-control-retries',
    '* * * * *',
    $cron$select public.invoke_group_call_control_dispatch();$cron$
  );
end;
$$;

notify pgrst, 'reload schema';
