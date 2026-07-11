import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WindowsPushService {
  WindowsPushService._();

  static const _channel = MethodChannel('chat_app/windows_push');
  static const _cachedChannelUriKey = 'chat_app.wns.channel_uri';
  static const _remoteId = String.fromEnvironment('WNS_AAD_REMOTE_ID');
  static void Function(Map<String, dynamic>)? _activationHandler;
  static bool _activationBridgeReady = false;

  static bool get isAvailable =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  static Future<void> initialize(
    void Function(Map<String, dynamic>) onActivation,
  ) async {
    if (!isAvailable) {
      return;
    }
    _activationHandler = onActivation;
    if (!_activationBridgeReady) {
      _activationBridgeReady = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'pushActivated') {
          _emitActivation(call.arguments?.toString());
          return null;
        }
        throw MissingPluginException('Unsupported Windows push method.');
      });
    }
    try {
      final initial = await _channel.invokeMethod<String>(
        'getInitialActivation',
      );
      _emitActivation(initial);
    } catch (error) {
      debugPrint('[Notifications] Windows activation bridge skipped: $error');
    }
  }

  static Future<String?> requestChannelUri() async {
    if (!isAvailable || _remoteId.isEmpty) {
      return null;
    }
    final channelUri = await _channel.invokeMethod<String>(
      'requestChannelUri',
      {'remoteId': _remoteId},
    );
    if (channelUri == null || channelUri.isEmpty) {
      return null;
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_cachedChannelUriKey, channelUri);
    return channelUri;
  }

  static Future<String?> cachedChannelUri() async {
    if (!isAvailable) {
      return null;
    }
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_cachedChannelUriKey);
  }

  static Future<void> clearCachedChannelUri() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_cachedChannelUriKey);
  }

  static void _emitActivation(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return;
    }
    Map<String, dynamic>? data;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        data = decoded.map((key, value) => MapEntry('$key', value));
      }
    } catch (_) {
      final query = Uri(query: raw).queryParameters;
      if (query.isNotEmpty) {
        data = query;
      }
    }
    if (data != null) {
      _activationHandler?.call(data);
    }
  }
}
