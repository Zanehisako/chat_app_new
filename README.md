# chat_app

A modern Flutter realtime direct-messaging UI with local preview data and Supabase auth.

## Run locally

```sh
flutter run
```

Without Supabase environment values, the app runs against local seed messages.

## Run with Supabase

1. Apply database changes through migrations:

```sh
npx supabase login
npx supabase link --project-ref your-project-ref
npx supabase db push
```

The migration files in `supabase/migrations/` create profiles, one-to-one
conversations, realtime messages, per-recipient receipts, RLS policies, auth
triggers, and existing-message receipt backfills. `supabase/schema.sql` is the
full schema snapshot for reference.

2. In Supabase Auth, enable Email, Phone, and Google providers.
3. Enable email confirmation if you want signups to require confirm-email.
4. Add redirect URLs:
   - Native: `chatapp://login-callback`
   - Web dev: your local web origin, for example `http://127.0.0.1:5060`
5. Run with your project values:

```sh
flutter run \
  --dart-define=SUPABASE_URL=https://your-project.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=your-publishable-key \
  --dart-define=SUPABASE_AUTH_REDIRECT_URL=chatapp://login-callback
```

`SUPABASE_ANON_KEY` is also supported for older projects.

On web, omit `SUPABASE_AUTH_REDIRECT_URL` to use the current origin. For native
apps, keep `chatapp://login-callback` unless you also update Android and iOS
deep-link settings.

Email/password, phone SMS OTP, forgot-password links, password recovery, Google
OAuth, direct user search, and sign out are handled in the app. Realtime
messages are only sent after Supabase has an authenticated user session.

## Audio/video calls

Calls are foreground, in-app 1:1 audio/video sessions in direct conversations.
The app uses the local reusable package at `packages/realtime_calls`, with
Supabase carrying only call signaling. Audio/video media flows through WebRTC.

Apply the call migration with the same Supabase workflow:

```sh
npx supabase db push
```

Deploy the TURN credential Edge Function:

```sh
npx supabase functions deploy turn-credentials
npx supabase secrets set \
  TURN_SECRET=your-shared-turn-rest-secret \
  TURN_URLS=turn:turn.example.com:3478?transport=udp,turn:turn.example.com:3478?transport=tcp
```

For local testing without deploying the function, pass direct self-hosted TURN
values:

```sh
flutter run \
  --dart-define=CALL_TURN_URLS=turn:turn.example.com:3478?transport=udp \
  --dart-define=CALL_TURN_USERNAME=username \
  --dart-define=CALL_TURN_CREDENTIAL=password
```

If TURN credentials are missing, the app falls back to public STUN by default
for local connectivity checks. Use
`--dart-define=CALL_ALLOW_PUBLIC_STUN_FALLBACK=false` to require TURN.
Production internet calls should use TURN.
