import 'dart:async';

import 'package:chat_app/src/notification_registration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const firstScope = NotificationRegistrationScope(
    backendOrigin: 'https://project.supabase.co',
    userId: 'user-one',
    platform: 'android',
  );
  const secondScope = NotificationRegistrationScope(
    backendOrigin: 'https://project.supabase.co',
    userId: 'user-two',
    platform: 'web',
  );

  test('enable requests permission and registers the active account', () async {
    final provider = _FakePushTokenProvider();
    final registry = _FakePushTokenRegistry();
    final preferences = _MemoryNotificationPreferences();
    final controller = NotificationRegistrationController(
      provider: provider,
      registry: registry,
      preferences: preferences,
    );

    await controller.enable(firstScope);

    expect(provider.permissionRequests, 1);
    expect(registry.registered, [(firstScope.accountKey, 'test-token')]);
    expect(await preferences.isEnabled(firstScope), isTrue);
    expect(
      controller.status.value.state,
      NotificationRegistrationState.enabled,
    );
  });

  test('denied permission does not register or retain opt-in', () async {
    final provider = _FakePushTokenProvider(
      requestedPermission: PushPermissionStatus.denied,
    );
    final registry = _FakePushTokenRegistry();
    final preferences = _MemoryNotificationPreferences();
    final controller = NotificationRegistrationController(
      provider: provider,
      registry: registry,
      preferences: preferences,
    );

    await controller.enable(firstScope);

    expect(registry.registered, isEmpty);
    expect(await preferences.isEnabled(firstScope), isFalse);
    expect(controller.status.value.state, NotificationRegistrationState.denied);
  });

  test('refresh retries a prior registration failure', () async {
    final provider = _FakePushTokenProvider();
    final registry = _FakePushTokenRegistry(failRegistrations: 1);
    final preferences = _MemoryNotificationPreferences();
    await preferences.setEnabled(firstScope, enabled: true);
    final controller = NotificationRegistrationController(
      provider: provider,
      registry: registry,
      preferences: preferences,
    );

    await controller.load(firstScope);
    expect(controller.status.value.state, NotificationRegistrationState.failed);

    await controller.load(firstScope);
    expect(
      controller.status.value.state,
      NotificationRegistrationState.enabled,
    );
    expect(registry.registered, [(firstScope.accountKey, 'test-token')]);
  });

  test('refresh reports permission revoked without prompting again', () async {
    final provider = _FakePushTokenProvider(
      currentPermission: PushPermissionStatus.denied,
    );
    final preferences = _MemoryNotificationPreferences();
    await preferences.setEnabled(firstScope, enabled: true);
    final controller = NotificationRegistrationController(
      provider: provider,
      registry: _FakePushTokenRegistry(),
      preferences: preferences,
    );

    await controller.load(firstScope);

    expect(provider.permissionRequests, 0);
    expect(controller.status.value.state, NotificationRegistrationState.denied);
  });

  test('missing provider token fails without persisting opt-in', () async {
    final preferences = _MemoryNotificationPreferences();
    final controller = NotificationRegistrationController(
      provider: _FakePushTokenProvider(token: null),
      registry: _FakePushTokenRegistry(),
      preferences: preferences,
    );

    await controller.enable(firstScope);

    expect(await preferences.isEnabled(firstScope), isFalse);
    expect(controller.status.value.state, NotificationRegistrationState.failed);
  });

  test('token refresh and preferences stay isolated by account', () async {
    final provider = _FakePushTokenProvider();
    final registry = _FakePushTokenRegistry();
    final preferences = _MemoryNotificationPreferences();
    await preferences.setEnabled(firstScope, enabled: true);
    final controller = NotificationRegistrationController(
      provider: provider,
      registry: registry,
      preferences: preferences,
    );

    await controller.registerRefreshedToken(firstScope, 'first-refresh');
    await controller.registerRefreshedToken(secondScope, 'second-refresh');

    expect(registry.registered, [(firstScope.accountKey, 'first-refresh')]);
    expect(await preferences.isEnabled(secondScope), isFalse);
  });

  test('disable unregisters before clearing the preference', () async {
    final provider = _FakePushTokenProvider();
    final registry = _FakePushTokenRegistry();
    final preferences = _MemoryNotificationPreferences();
    await preferences.setEnabled(firstScope, enabled: true);
    final controller = NotificationRegistrationController(
      provider: provider,
      registry: registry,
      preferences: preferences,
    );

    await controller.disable(firstScope);

    expect(registry.unregistered, [(firstScope.accountKey, 'test-token')]);
    expect(await preferences.isEnabled(firstScope), isFalse);
    expect(
      controller.status.value.state,
      NotificationRegistrationState.disabled,
    );
  });

  test('disable waits for an active enable instead of being dropped', () async {
    final registrationStarted = Completer<void>();
    final continueRegistration = Completer<void>();
    final provider = _FakePushTokenProvider();
    final registry = _BlockingPushTokenRegistry(
      registrationStarted: registrationStarted,
      continueRegistration: continueRegistration,
    );
    final preferences = _MemoryNotificationPreferences();
    final controller = NotificationRegistrationController(
      provider: provider,
      registry: registry,
      preferences: preferences,
    );

    final enable = controller.enable(firstScope);
    await registrationStarted.future;
    final disable = controller.disable(firstScope);
    continueRegistration.complete();
    await Future.wait([enable, disable]);

    expect(registry.registered, [(firstScope.accountKey, 'test-token')]);
    expect(registry.unregistered, [(firstScope.accountKey, 'test-token')]);
    expect(await preferences.isEnabled(firstScope), isFalse);
    expect(
      controller.status.value.state,
      NotificationRegistrationState.disabled,
    );
  });

  test('failures expose a generic message without provider details', () async {
    final provider = _FakePushTokenProvider();
    final registry = _FakePushTokenRegistry(
      failure: StateError('secret-token-value'),
      failRegistrations: 1,
    );
    final preferences = _MemoryNotificationPreferences();
    final controller = NotificationRegistrationController(
      provider: provider,
      registry: registry,
      preferences: preferences,
    );

    await controller.enable(firstScope);

    expect(controller.status.value.message, isNot(contains('secret-token')));
    expect(controller.status.value.state, NotificationRegistrationState.failed);
  });

  test(
    'RPC registry uses the exact five-parameter function signature',
    () async {
      String? function;
      Map<String, dynamic>? parameters;
      final registry = RpcPushTokenRegistry(
        currentUserId: () => firstScope.userId,
        invoke: (name, params) async {
          function = name;
          parameters = params;
          return null;
        },
      );

      await registry.register(scope: firstScope, token: 'test-token');

      expect(function, 'register_push_device_token');
      expect(parameters, {
        'p_provider': 'fcm',
        'p_token': 'test-token',
        'p_platform': 'android',
        'p_device_label': 'android',
        'p_expires_at': null,
      });
    },
  );

  test('RPC registry rejects an account change before writing', () async {
    var invoked = false;
    final registry = RpcPushTokenRegistry(
      currentUserId: () => secondScope.userId,
      invoke: (name, params) async {
        invoked = true;
        return null;
      },
    );

    await expectLater(
      registry.register(scope: firstScope, token: 'test-token'),
      throwsStateError,
    );
    expect(invoked, isFalse);
  });
}

class _FakePushTokenProvider implements PushTokenProvider {
  _FakePushTokenProvider({
    this.requestedPermission = PushPermissionStatus.authorized,
    this.currentPermission = PushPermissionStatus.authorized,
    this.token = 'test-token',
  });

  final PushPermissionStatus requestedPermission;
  final PushPermissionStatus currentPermission;
  final String? token;
  int permissionRequests = 0;

  @override
  bool get isSupported => true;

  @override
  Future<String?> getToken() async => token;

  @override
  Future<PushPermissionStatus> permissionStatus() async => currentPermission;

  @override
  Future<PushPermissionStatus> requestPermission() async {
    permissionRequests += 1;
    return requestedPermission;
  }
}

class _FakePushTokenRegistry implements PushTokenRegistry {
  _FakePushTokenRegistry({this.failRegistrations = 0, this.failure});

  int failRegistrations;
  final Object? failure;
  final List<(String, String)> registered = [];
  final List<(String, String)> unregistered = [];

  @override
  Future<void> register({
    required NotificationRegistrationScope scope,
    required String token,
  }) async {
    if (failRegistrations > 0) {
      failRegistrations -= 1;
      throw failure ?? StateError('registration failed');
    }
    registered.add((scope.accountKey, token));
  }

  @override
  Future<void> unregister({
    required NotificationRegistrationScope scope,
    required String token,
  }) async {
    unregistered.add((scope.accountKey, token));
  }
}

class _BlockingPushTokenRegistry extends _FakePushTokenRegistry {
  _BlockingPushTokenRegistry({
    required this.registrationStarted,
    required this.continueRegistration,
  });

  final Completer<void> registrationStarted;
  final Completer<void> continueRegistration;

  @override
  Future<void> register({
    required NotificationRegistrationScope scope,
    required String token,
  }) async {
    registrationStarted.complete();
    await continueRegistration.future;
    await super.register(scope: scope, token: token);
  }
}

class _MemoryNotificationPreferences implements NotificationPreferenceStore {
  final Map<String, bool> _values = {};

  @override
  Future<bool> isEnabled(NotificationRegistrationScope scope) async {
    return _values[scope.accountKey] ?? false;
  }

  @override
  Future<void> setEnabled(
    NotificationRegistrationScope scope, {
    required bool enabled,
  }) async {
    _values[scope.accountKey] = enabled;
  }
}
