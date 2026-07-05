# chat_app

A modern Flutter realtime chat UI with local preview data and Supabase auth.

## Run locally

```sh
flutter run
```

Without Supabase environment values, the app runs against local seed messages.

## Run with Supabase

1. Apply `supabase/schema.sql` in your Supabase SQL editor.
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
OAuth, and sign out are handled in the app. Realtime messages are only sent after
Supabase has an authenticated user session.
