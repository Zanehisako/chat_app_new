import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseConfig {
  SupabaseConfig._();

  static const url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://pwkujcclyhtmpynmysws.supabase.co',
  );
  static const publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: 'sb_publishable_LYOkcHs1XhZFspv6IoR_6g_9GSW-onV',
  );
  static const anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const _configuredAuthRedirectUrl = String.fromEnvironment(
    'SUPABASE_AUTH_REDIRECT_URL',
  );
  static const nativeAuthRedirectUrl = 'chatapp://login-callback';

  static bool _initialized = false;

  static String get key => publishableKey.isNotEmpty ? publishableKey : anonKey;

  static bool get isConfigured => url.isNotEmpty && key.isNotEmpty;

  static String get authRedirectUrl {
    if (_configuredAuthRedirectUrl.isNotEmpty) {
      return _configuredAuthRedirectUrl;
    }

    if (kIsWeb) {
      return Uri.base.origin;
    }

    return nativeAuthRedirectUrl;
  }

  static Future<void> initialize() async {
    if (!isConfigured || _initialized) {
      return;
    }

    await Supabase.initialize(url: url, publishableKey: key);

    _initialized = true;
  }

  static SupabaseClient? get client {
    if (!_initialized) {
      return null;
    }

    return Supabase.instance.client;
  }
}
