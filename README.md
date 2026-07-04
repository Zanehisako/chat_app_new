# chat_app

A modern Flutter chat UI with local preview data and a Supabase-ready message
repository.

## Run locally

```sh
flutter run
```

Without Supabase environment values, the app runs against local seed messages.

## Run with Supabase

1. Apply `supabase/schema.sql` in your Supabase SQL editor.
2. Enable anonymous or normal auth for users who will send messages.
3. Run with your project values:

```sh
flutter run \
  --dart-define=SUPABASE_URL=https://your-project.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=your-publishable-key
```

`SUPABASE_ANON_KEY` is also supported for older projects.

For a quick authenticated demo, enable anonymous auth in Supabase and add:

```sh
--dart-define=SUPABASE_AUTO_ANON_AUTH=true
```
