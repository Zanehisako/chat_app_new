import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseConfig {
  SupabaseConfig._();

  static const url = String.fromEnvironment('SUPABASE_URL');
  static const publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );
  static const anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const autoAnonymousAuth = bool.fromEnvironment(
    'SUPABASE_AUTO_ANON_AUTH',
  );

  static bool _initialized = false;

  static String get key => publishableKey.isNotEmpty ? publishableKey : anonKey;

  static bool get isConfigured => url.isNotEmpty && key.isNotEmpty;

  static Future<void> initialize() async {
    if (!isConfigured || _initialized) {
      return;
    }

    final supabase = await Supabase.initialize(url: url, publishableKey: key);

    if (autoAnonymousAuth && supabase.client.auth.currentSession == null) {
      await supabase.client.auth.signInAnonymously();
    }

    _initialized = true;
  }

  static SupabaseClient? get client {
    if (!_initialized) {
      return null;
    }

    return Supabase.instance.client;
  }
}
