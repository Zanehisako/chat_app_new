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

## Push notifications and offline sends

Outgoing authenticated messages are first saved in a local outbox. Media bytes
are persisted with the queue in an app-support SQLite database (or IndexedDB on
web) before the composer is cleared. When the network returns, the app uploads
media, inserts the message with its stable outbox id, and removes the durable
queue record only after Supabase accepts the row. The database trigger enqueues
the recipient push job only after that insert.

| Platform | Delivery |
| --- | --- |
| Android, web | FCM remote push |
| iOS, macOS | Not configured; Apple registration requires a developer account |
| Windows | WNS when built with the Windows App SDK bridge |
| Linux | Local notifications only while the app is running; use the web app for remote web push |

### Firebase client setup

Firebase is used only for FCM delivery; Supabase remains the auth, database,
storage, and notification-job backend. Android (`com.example.chat_app`) and web
are registered in Firebase project `chat-app-92f45`. Apple targets are not
registered. A public web Firebase configuration and VAPID key are bundled for
the registered web app. A normal `flutter run -d chrome` uses
`chat-app-92f45`; use Dart defines only for another Firebase project:

```sh
flutter run \
  --dart-define=FIREBASE_API_KEY=... \
  --dart-define=FIREBASE_APP_ID=... \
  --dart-define=FIREBASE_MESSAGING_SENDER_ID=... \
  --dart-define=FIREBASE_PROJECT_ID=...
```

`ChatFirebaseOptions` prefers `FIREBASE_ANDROID_APP_ID`,
`FIREBASE_IOS_APP_ID`, `FIREBASE_MACOS_APP_ID`, and `FIREBASE_WEB_APP_ID` (and
the matching `FIREBASE_<PLATFORM>_API_KEY` values), then falls back to the
generic values above for one-target builds. `flutterfire configure` is the
recommended way to obtain the correct per-platform values.

The checked-in Dart and `web/firebase-config.js` public values belong to
`chat-app-92f45`. Override them for a different project.

Android 13+ notification permission is declared in the Android manifest and is
requested at runtime. Android devices still need Google Play services.

### Supabase dispatcher setup

Apply the migration and deploy the Edge Function without JWT verification. The
database-only dispatch secret protects its `pg_net` invocation.

Create a dedicated Google service account and a project custom role containing
only `cloudmessaging.messages.create`. Bind that role to the service account,
generate one JSON key, upload the minified JSON as
`FCM_SERVICE_ACCOUNT_JSON`, and delete the local key file immediately. The live
project uses service account `chat-push-dispatch` and custom role
`chatPushSender`; do not grant it Firebase Admin or project-wide roles.

```sh
npx supabase db push
npx supabase functions deploy notification-dispatch --no-verify-jwt
npx supabase secrets set \
  NOTIFICATION_DISPATCH_SECRET=replace-with-a-random-secret-of-at-least-32-characters \
  FCM_PROJECT_ID=your-firebase-project-id \
  FCM_SERVICE_ACCOUNT_JSON='your-single-line-service-account-json' \
  WEB_APP_URL=https://chat-app-92f45.web.app
```

Deploy the production web build to the configured Firebase Hosting site:

```sh
flutter build web
npx -y firebase-tools@latest deploy --only hosting --project chat-app-92f45
```

Set the protected dispatch configuration as a database owner, using the same
secret configured above:

```sql
insert into public.push_notification_dispatch_config (
  id,
  function_url,
  dispatch_secret,
  enabled
)
values (
  true,
  'https://your-project-ref.supabase.co/functions/v1/notification-dispatch',
  'replace-with-the-same-random-secret-of-at-least-32-characters',
  true
)
on conflict (id) do update
  set function_url = excluded.function_url,
      dispatch_secret = excluded.dispatch_secret,
      enabled = excluded.enabled,
      updated_at = now();
```

The migration disables any previously enabled dispatcher row that lacks an HTTPS
endpoint or a 32-character secret. It schedules a five-minute `pg_cron` fallback
and immediately invokes the function through `pg_net` for each new job. Jobs are
claimed per device with row locks, stale `sending` claims are recovered after 15
minutes, transient provider errors use exponential backoff, and invalid device
tokens are disabled.

### Windows WNS setup

The WNS dispatcher path is enabled by storing a `provider = 'wns'` channel URI
in `push_device_tokens`. Build the Windows runner with `CHAT_APP_ENABLE_WNS=ON`
and `CHAT_APP_WINDOWS_APP_SDK_ROOT` pointing to the installed
`Microsoft.WindowsAppSDK` NuGet package; the bridge then requests a fresh
channel URI on every launch. In PowerShell:

```powershell
$env:CHAT_APP_ENABLE_WNS = 'ON'
$env:CHAT_APP_WINDOWS_APP_SDK_ROOT = 'C:\\path\\to\\Microsoft.WindowsAppSDK'
flutter build windows --dart-define=WNS_AAD_REMOTE_ID=your-azure-object-id
```

`WNS_AAD_REMOTE_ID` is the Azure application Object ID and must be supplied to
every Windows run or build that should register a channel URI.

Before shipping, package the app with its Windows App SDK/COM activation setup,
map its Package Family Name to the Azure app registration, and configure these
Supabase secrets for the Edge Function:

```sh
npx supabase secrets set \
  WNS_TENANT_ID=... \
  WNS_CLIENT_ID=... \
  WNS_CLIENT_SECRET=...
```

WNS Channel URIs expire, so the app never treats the cached URI as permanent;
it requests and registers a fresh one every launch.

### Targeted checks

```sh
flutter analyze
flutter test
flutter build web
npx -y deno@latest test --allow-env supabase/functions/notification-dispatch
npx supabase db push --dry-run
```

`supabase test db` also exercises the token RPCs and delivery trigger, but it
requires a running local Docker daemon.

### Smoke checks

Verify foreground, background, and terminated delivery on Android, browser
service-worker delivery on web, and offline text/media sends followed by
reconnection. Apple push is not configured. Windows WNS remains an optional
phase that requires packaging and Azure setup. Notification payloads contain
only sender name, preview text, message id, and conversation id.
