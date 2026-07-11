import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum NotificationRegistrationState {
  disabled,
  enabling,
  enabled,
  denied,
  unsupported,
  failed,
}

enum PushPermissionStatus {
  notDetermined,
  denied,
  authorized,
  provisional,
  unsupported,
}

@immutable
class NotificationRegistrationStatus {
  const NotificationRegistrationStatus(this.state, {this.message});

  const NotificationRegistrationStatus.disabled()
    : this(NotificationRegistrationState.disabled);

  final NotificationRegistrationState state;
  final String? message;

  bool get isEnabled => state == NotificationRegistrationState.enabled;
  bool get isBusy => state == NotificationRegistrationState.enabling;
}

@immutable
class NotificationRegistrationScope {
  const NotificationRegistrationScope({
    required this.backendOrigin,
    required this.userId,
    required this.platform,
  });

  final String backendOrigin;
  final String userId;
  final String platform;

  String get accountKey => '${backendOrigin.toLowerCase()}|$userId';
}

abstract interface class PushTokenProvider {
  bool get isSupported;

  Future<PushPermissionStatus> permissionStatus();

  Future<PushPermissionStatus> requestPermission();

  Future<String?> getToken();
}

abstract interface class PushTokenRegistry {
  Future<void> register({
    required NotificationRegistrationScope scope,
    required String token,
  });

  Future<void> unregister({
    required NotificationRegistrationScope scope,
    required String token,
  });
}

abstract interface class NotificationPreferenceStore {
  Future<bool> isEnabled(NotificationRegistrationScope scope);

  Future<void> setEnabled(
    NotificationRegistrationScope scope, {
    required bool enabled,
  });
}

class SharedPreferencesNotificationPreferenceStore
    implements NotificationPreferenceStore {
  SharedPreferencesNotificationPreferenceStore({SharedPreferencesAsync? prefs})
    : _prefs = prefs ?? SharedPreferencesAsync();

  static const _prefix = 'chat_app.notifications.enabled.';
  final SharedPreferencesAsync _prefs;

  @override
  Future<bool> isEnabled(NotificationRegistrationScope scope) async {
    return await _prefs.getBool(_key(scope)) ?? false;
  }

  @override
  Future<void> setEnabled(
    NotificationRegistrationScope scope, {
    required bool enabled,
  }) {
    return _prefs.setBool(_key(scope), enabled);
  }

  String _key(NotificationRegistrationScope scope) {
    final encoded = base64Url
        .encode(utf8.encode(scope.accountKey))
        .replaceAll('=', '');
    return '$_prefix$encoded';
  }
}

typedef PushRpcInvoker =
    Future<Object?> Function(String function, Map<String, dynamic> params);

class RpcPushTokenRegistry implements PushTokenRegistry {
  const RpcPushTokenRegistry({
    required this.currentUserId,
    required this.invoke,
  });

  final String? Function() currentUserId;
  final PushRpcInvoker invoke;

  @override
  Future<void> register({
    required NotificationRegistrationScope scope,
    required String token,
  }) async {
    _verifyAccount(scope);
    await invoke('register_push_device_token', {
      'p_provider': 'fcm',
      'p_token': token,
      'p_platform': scope.platform,
      'p_device_label': scope.platform,
      'p_expires_at': null,
    });
  }

  @override
  Future<void> unregister({
    required NotificationRegistrationScope scope,
    required String token,
  }) async {
    _verifyAccount(scope);
    await invoke('unregister_push_device_token', {
      'p_provider': 'fcm',
      'p_token': token,
    });
  }

  void _verifyAccount(NotificationRegistrationScope scope) {
    if (currentUserId() != scope.userId) {
      throw StateError(
        'The authenticated account changed during notification registration.',
      );
    }
  }
}

class NotificationRegistrationController {
  NotificationRegistrationController({
    required this.provider,
    required this.registry,
    required this.preferences,
  });

  final PushTokenProvider provider;
  final PushTokenRegistry registry;
  final NotificationPreferenceStore preferences;
  final ValueNotifier<NotificationRegistrationStatus> status = ValueNotifier(
    const NotificationRegistrationStatus.disabled(),
  );

  Future<void>? _operation;

  Future<void> load(NotificationRegistrationScope scope) {
    return _serialize(() => _refresh(scope));
  }

  Future<void> enable(NotificationRegistrationScope scope) {
    return _serialize(() async {
      if (!provider.isSupported) {
        _set(NotificationRegistrationState.unsupported);
        return;
      }
      _set(NotificationRegistrationState.enabling);
      try {
        final permission = await provider.requestPermission();
        if (!_isGranted(permission)) {
          await preferences.setEnabled(scope, enabled: false);
          _set(
            permission == PushPermissionStatus.denied
                ? NotificationRegistrationState.denied
                : NotificationRegistrationState.unsupported,
            message: permission == PushPermissionStatus.denied
                ? 'Notification permission is blocked in system or browser settings.'
                : null,
          );
          return;
        }
        await _registerCurrentToken(scope);
        await preferences.setEnabled(scope, enabled: true);
        _set(NotificationRegistrationState.enabled);
      } catch (_) {
        _set(
          NotificationRegistrationState.failed,
          message: 'Could not enable notifications. Try again.',
        );
      }
    });
  }

  Future<void> disable(NotificationRegistrationScope scope) {
    return _serialize(() async {
      try {
        final token = provider.isSupported ? await provider.getToken() : null;
        if (token != null && token.isNotEmpty) {
          await registry.unregister(scope: scope, token: token);
        }
        await preferences.setEnabled(scope, enabled: false);
        _set(NotificationRegistrationState.disabled);
      } catch (_) {
        _set(
          NotificationRegistrationState.failed,
          message: 'Could not disable notifications. Try again.',
        );
      }
    });
  }

  Future<void> registerRefreshedToken(
    NotificationRegistrationScope scope,
    String token,
  ) {
    return _serialize(() async {
      if (token.isEmpty || !await preferences.isEnabled(scope)) {
        return;
      }
      try {
        await registry.register(scope: scope, token: token);
        _set(NotificationRegistrationState.enabled);
      } catch (_) {
        _set(
          NotificationRegistrationState.failed,
          message: 'Could not refresh notification registration.',
        );
      }
    });
  }

  Future<void> _refresh(NotificationRegistrationScope scope) async {
    if (!provider.isSupported) {
      _set(NotificationRegistrationState.unsupported);
      return;
    }
    if (!await preferences.isEnabled(scope)) {
      _set(NotificationRegistrationState.disabled);
      return;
    }
    try {
      final permission = await provider.permissionStatus();
      if (permission == PushPermissionStatus.denied) {
        _set(
          NotificationRegistrationState.denied,
          message:
              'Notification permission is blocked in system or browser settings.',
        );
        return;
      }
      if (!_isGranted(permission)) {
        _set(NotificationRegistrationState.disabled);
        return;
      }
      await _registerCurrentToken(scope);
      _set(NotificationRegistrationState.enabled);
    } catch (_) {
      _set(
        NotificationRegistrationState.failed,
        message: 'Could not refresh notification registration.',
      );
    }
  }

  Future<void> _registerCurrentToken(
    NotificationRegistrationScope scope,
  ) async {
    final token = await provider.getToken();
    if (token == null || token.isEmpty) {
      throw StateError('The push provider did not return a token.');
    }
    await registry.register(scope: scope, token: token);
  }

  Future<void> _serialize(Future<void> Function() action) {
    final previous = _operation ?? Future<void>.value();
    final operation = previous
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .then<void>((_) => action());
    _operation = operation;
    return operation.whenComplete(() {
      if (identical(_operation, operation)) _operation = null;
    });
  }

  bool _isGranted(PushPermissionStatus permission) {
    return permission == PushPermissionStatus.authorized ||
        permission == PushPermissionStatus.provisional;
  }

  void _set(NotificationRegistrationState state, {String? message}) {
    status.value = NotificationRegistrationStatus(state, message: message);
  }

  void dispose() {
    status.dispose();
  }
}
