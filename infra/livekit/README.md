# LiveKit group calls

LiveKit Cloud is the default online media backend. The app never receives a permanent API credential: `group-call-token` checks Supabase membership and mints a 60-second room token. The files in this directory remain available for optional self-hosting.

## LiveKit Cloud production

1. Create a dedicated LiveKit Cloud API key. Rotate any key that has been copied into source code, logs, or chat.
2. Configure the linked Supabase project with `LIVEKIT_WS_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, and a random `GROUP_CALL_CONTROL_SECRET`. Remove `LIVEKIT_URL` and `LIVEKIT_SKIP_ROOM_CREATE` so there is one canonical endpoint and Cloud room creation remains enforced.
3. Deploy `group-call-token`, `livekit-webhook`, and `group-call-control`. The last two functions must keep JWT verification disabled as configured in `supabase/config.toml`.
4. In LiveKit Cloud Settings → Webhooks, add `https://<supabase-project>.supabase.co/functions/v1/livekit-webhook`, select the same LiveKit API key for signing, and send a test event.
5. Apply all Supabase migrations. Configure the protected `group_call_control_dispatch_config` row with the deployed `group-call-control` URL and the same control secret used by the Edge Function. The database invokes removal jobs immediately and retries them once per minute.

No credential values belong in tracked files. Recording, streaming, telephony, ingress, and egress are not part of this setup.

## Local Chrome development

Run `livekit-server --dev --bind 0.0.0.0`, then configure a development Supabase project with `LIVEKIT_WS_URL=ws://localhost:7880`, `LIVEKIT_API_KEY=devkey`, and `LIVEKIT_API_SECRET=secret`. The token function still creates each room explicitly, including its 50-person cap. Do not apply these values to the production Supabase project.

## First VM deployment

1. Use a public Linux VM with a DNS name such as `livekit.example.com`.
2. Copy `.env.example` to `.env`, choose a pinned LiveKit image, and copy `livekit.yaml.example` to `livekit.yaml`.
3. Replace the placeholder API key/secret in `livekit.yaml`. Use the same values for the Supabase Edge Function secrets `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET`.
4. Copy `Caddyfile.example` to `Caddyfile` and replace the hostname. Caddy provisions HTTPS for the signaling endpoint.
5. Open TCP `80`, `443`, and `7881`, plus UDP `3478` and `50000-60000`. Keep the VM's public IP stable.
6. Start with `docker compose --env-file .env --profile control-worker up -d` and verify `https://livekit.example.com` resolves. Set `LIVEKIT_WS_URL=wss://livekit.example.com` for the token function. The profile polls `group-call-control` every five seconds so removed members are disconnected without another scheduler.

The initial target is one room with up to 50 members. Supabase membership remains the source of truth; removed members are disconnected by the `group-call-control` function. Self-hosted LiveKit does not provide managed token revocation, so short-lived tokens and removal calls are intentional.

## Supabase function secrets

Configure these for `group-call-token`, `livekit-webhook`, and `group-call-control`:

```text
LIVEKIT_WS_URL=wss://livekit.example.com
LIVEKIT_API_KEY=...
LIVEKIT_API_SECRET=...
GROUP_CALL_CONTROL_SECRET=<at least 32 random characters>
```

Configure the LiveKit webhook URL as `https://<supabase-project>.supabase.co/functions/v1/livekit-webhook`, signed with the same API key/secret. Set the matching `GROUP_CALL_CONTROL_URL` and `GROUP_CALL_CONTROL_SECRET` in `.env` for the optional worker profile; it calls `group-call-control` with `x-dispatch-secret`.

## Growing beyond one node

Keep Redis and move LiveKit to the official distributed/Kubernetes deployment pattern when multiple nodes or regions are needed. Re-run a LiveKit load test with the intended audio/video mix before raising the 50-person room limit. This repository intentionally does not pretend that a local Compose VM is a highly available deployment.
