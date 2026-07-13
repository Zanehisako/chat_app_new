import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_firebase_options.dart';
import 'notification_registration.dart';
import 'supabase_config.dart';
import 'web_notification_presenter.dart';
import 'windows_push_service.dart';

@pragma('vm:entry-point')
Future<void> chatAppFirebaseMessagingBackgroundHandler(
  RemoteMessage message,
) async {
  try {
    final options = ChatFirebaseOptions.currentPlatform;
    if (Firebase.apps.isEmpty) {
      if (options == null) {
        await Firebase.initializeApp();
      } else {
        await Firebase.initializeApp(options: options);
      }
    }
  } catch (_) {
    // Background handlers must never crash app startup.
  }
}

class NotificationRoute {
  const NotificationRoute({required this.conversationId, this.messageId});

  final String conversationId;
  final String? messageId;

  static NotificationRoute? fromData(Map<String, dynamic> data) {
    final conversationId =
        data['conversation_id']?.toString().trim() ??
        data['conversationId']?.toString().trim() ??
        '';
    if (conversationId.isEmpty) {
      return null;
    }
    final messageId = data['message_id']?.toString().trim();
    return NotificationRoute(
      conversationId: conversationId,
      messageId: messageId == null || messageId.isEmpty ? null : messageId,
    );
  }
}

class FirebaseMessagingBackgroundHandlerRegistrar {
  FirebaseMessagingBackgroundHandlerRegistrar._();

  static void register() {
    try {
      FirebaseMessaging.onBackgroundMessage(
        chatAppFirebaseMessagingBackgroundHandler,
      );
    } catch (_) {
      // The web/test runtime can throw before Firebase is configured.
    }
  }
}

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static const _androidChannel = AndroidNotificationChannel(
    'chat_messages',
    'Chat messages',
    description: 'New direct messages and call updates.',
    importance: Importance.high,
  );

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  final WebNotificationPresenter _webNotifications = WebNotificationPresenter();
  final StreamController<NotificationRoute> _routeController =
      StreamController<NotificationRoute>.broadcast();
  StreamSubscription<String>? _tokenSubscription;
  StreamSubscription<RemoteMessage>? _foregroundSubscription;
  StreamSubscription<RemoteMessage>? _openedSubscription;
  bool _localReady = false;
  bool _firebaseReady = false;
  SupabaseClient? _client;
  NotificationRoute? _pendingRoute;
  NotificationRegistrationController? _registrationController;
  NotificationRegistrationScope? _registrationScope;
  VoidCallback? _registrationListener;
  NotificationRegistrationState? _lastLoggedRegistrationState;

  final ValueNotifier<NotificationRegistrationStatus> registrationStatus =
      ValueNotifier(const NotificationRegistrationStatus.disabled());

  Stream<NotificationRoute> get routes => _routeController.stream;

  bool get showsAppRunningNotificationsOnly =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  NotificationRoute? takePendingRoute() {
    final route = _pendingRoute;
    _pendingRoute = null;
    return route;
  }

  Future<void> initialize({SupabaseClient? client}) async {
    _client = client;
    await _initializeLocalNotifications();
    if (kIsWeb) {
      final conversationId = Uri.base.queryParameters['conversation'];
      if (conversationId != null && conversationId.trim().isNotEmpty) {
        _emitRoute({'conversation_id': conversationId});
      }
    }
    if (WindowsPushService.isAvailable) {
      await WindowsPushService.initialize(_emitRoute);
      await refreshRegistration(client: client);
      return;
    }
    if (!_supportsFcm) {
      return;
    }
    await _initializeFirebase();
    if (_firebaseReady) {
      _foregroundSubscription ??= FirebaseMessaging.onMessage.listen(
        _showForegroundMessage,
      );
      _openedSubscription ??= FirebaseMessaging.onMessageOpenedApp.listen(
        _handleOpenedMessage,
      );
      try {
        final initialMessage = await FirebaseMessaging.instance
            .getInitialMessage();
        if (initialMessage != null) {
          _emitRoute(initialMessage.data);
        }
      } catch (error) {
        debugPrint('[Notifications] Initial notification skipped: $error');
      }
      _ensureTokenRefreshSubscription();
      await refreshRegistration(client: client);
    }
  }

  @Deprecated('Use refreshRegistration. This method no longer prompts.')
  Future<void> registerDeviceToken({SupabaseClient? client}) async {
    await refreshRegistration(client: client);
  }

  Future<void> refreshRegistration({SupabaseClient? client}) async {
    _client = client ?? _client;
    final supabase = _client;
    final user = supabase?.auth.currentUser;
    if (supabase == null || user == null) {
      return;
    }
    if (WindowsPushService.isAvailable) {
      await _registerWindowsDeviceToken(supabase: supabase, userId: user.id);
      return;
    }
    if (!_supportsFcm || !_firebaseReady) {
      return;
    }

    final registration = _registrationFor(supabase);
    if (registration == null) return;
    await registration.controller.load(registration.scope);
  }

  Future<void> enableNotifications({SupabaseClient? client}) async {
    _client = client ?? _client;
    final supabase = _client;
    if (supabase == null || !_firebaseReady) {
      registrationStatus.value = const NotificationRegistrationStatus(
        NotificationRegistrationState.unsupported,
      );
      return;
    }
    final registration = _registrationFor(supabase);
    if (registration == null) return;
    debugPrint('[Notifications] Enable requested for $_platformLabel.');
    await _requestLocalNotificationPermission();
    await registration.controller.enable(registration.scope);
    if (registration.controller.status.value.isEnabled) {
      debugPrint('[Notifications] Push token registered for $_platformLabel.');
    }
  }

  Future<void> disableNotifications({SupabaseClient? client}) async {
    _client = client ?? _client;
    final supabase = _client;
    if (supabase == null) return;
    final registration = _registrationFor(supabase);
    if (registration == null) return;
    debugPrint('[Notifications] Disable requested for $_platformLabel.');
    await registration.controller.disable(registration.scope);
  }

  Future<bool> unregisterDeviceToken({
    SupabaseClient? client,
    String? userId,
  }) async {
    final supabase = client ?? _client;
    final ownerId = userId ?? supabase?.auth.currentUser?.id;
    if (supabase == null || ownerId == null) {
      return false;
    }
    if (supabase.auth.currentUser?.id != ownerId) {
      return false;
    }

    try {
      if (WindowsPushService.isAvailable) {
        final channelUri = await WindowsPushService.cachedChannelUri();
        if (channelUri != null && channelUri.isNotEmpty) {
          await supabase.rpc(
            'unregister_push_device_token',
            params: {'p_provider': 'wns', 'p_token': channelUri},
          );
        }
        await WindowsPushService.clearCachedChannelUri();
        return true;
      }
      final token = _firebaseReady ? await _firebaseToken() : null;
      if (token == null || token.isEmpty) {
        return true;
      }
      final scope = _scopeFor(supabase, ownerId);
      final registry = _registryFor(supabase);
      await registry.unregister(scope: scope, token: token);
      debugPrint(
        '[Notifications] Push token unregistered for $_platformLabel.',
      );
      return true;
    } catch (error) {
      debugPrint('[Notifications] Push token unregister skipped: $error');
      return false;
    }
  }

  Future<void> dispose() async {
    await _tokenSubscription?.cancel();
    await _foregroundSubscription?.cancel();
    await _openedSubscription?.cancel();
    _tokenSubscription = null;
    _foregroundSubscription = null;
    _openedSubscription = null;
    _clearRegistrationController();
  }

  Future<void> _initializeFirebase() async {
    if (_firebaseReady || !_supportsFcm) {
      return;
    }
    try {
      if (Firebase.apps.isEmpty) {
        final options = ChatFirebaseOptions.currentPlatform;
        if (options == null) {
          await Firebase.initializeApp();
        } else {
          await Firebase.initializeApp(options: options);
        }
      }
      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
            // Foreground messages are rendered by the local-notification path
            // below, avoiding duplicate alerts on Apple platforms.
            alert: false,
            badge: true,
            sound: true,
          );
      _firebaseReady = true;
      debugPrint(
        '[Notifications] Firebase messaging ready for $_platformLabel.',
      );
    } catch (error) {
      debugPrint('[Notifications] Firebase initialization skipped: $error');
    }
  }

  Future<void> _initializeLocalNotifications() async {
    if (kIsWeb || _localReady) {
      return;
    }
    try {
      await _localNotifications.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
          macOS: DarwinInitializationSettings(),
          linux: LinuxInitializationSettings(defaultActionName: 'Open'),
          windows: WindowsInitializationSettings(
            appName: 'Chat App',
            appUserModelId: 'com.example.chat_app',
            guid: '4d2e6ff9-1e90-4db3-a495-e1658fb93f4b',
          ),
        ),
        onDidReceiveNotificationResponse: _handleLocalNotificationResponse,
      );

      await _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(_androidChannel);

      _localReady = true;
    } catch (error) {
      debugPrint('[Notifications] Local notifications unavailable: $error');
    }
  }

  Future<void> _requestLocalNotificationPermission() async {
    try {
      await _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      await _localNotifications
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      await _localNotifications
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (error) {
      debugPrint('[Notifications] Permission request skipped: $error');
    }
  }

  Future<void> _showForegroundMessage(RemoteMessage message) async {
    final notification = message.notification;
    final title =
        notification?.title ??
        message.data['title']?.toString() ??
        'New message';
    final body = notification?.body ?? message.data['body']?.toString() ?? '';
    if (kIsWeb) {
      final shown = await _webNotifications.show(
        title: title,
        body: body,
        conversationId: message.data['conversation_id']?.toString(),
        messageId: message.data['message_id']?.toString(),
      );
      if (!shown) {
        debugPrint('[Notifications] Foreground web notification not shown.');
      }
      return;
    }
    await _showLocalMessage(title: title, body: body, data: message.data);
  }

  Future<void> showAppRunningMessage({
    required String title,
    required String body,
    required String conversationId,
    String? messageId,
  }) async {
    if (!showsAppRunningNotificationsOnly) {
      return;
    }
    await _initializeLocalNotifications();
    final data = <String, dynamic>{
      'type': 'message',
      'conversation_id': conversationId,
    };
    if (messageId != null) {
      data['message_id'] = messageId;
    }
    await _showLocalMessage(title: title, body: body, data: data);
  }

  Future<void> _showLocalMessage({
    required String title,
    required String body,
    required Map<String, dynamic> data,
  }) async {
    if (!_localReady) {
      return;
    }
    final id = DateTime.now().millisecondsSinceEpoch.remainder(2147483647);

    await _localNotifications.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'chat_messages',
          'Chat messages',
          channelDescription: 'New direct messages and call updates.',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
        macOS: DarwinNotificationDetails(),
        linux: LinuxNotificationDetails(
          category: LinuxNotificationCategory.imReceived,
          urgency: LinuxNotificationUrgency.normal,
        ),
        windows: WindowsNotificationDetails(),
      ),
      payload: jsonEncode(data),
    );
  }

  void _handleOpenedMessage(RemoteMessage message) {
    _emitRoute(message.data);
  }

  void _handleLocalNotificationResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map) {
        _emitRoute(decoded.map((key, value) => MapEntry('$key', value)));
      }
    } catch (error) {
      debugPrint('[Notifications] Invalid notification payload: $error');
    }
  }

  @visibleForTesting
  void handleNotificationData(Map<String, dynamic> data) {
    _emitRoute(data);
  }

  void _emitRoute(Map<String, dynamic> data) {
    final route = NotificationRoute.fromData(data);
    if (route == null) {
      return;
    }
    _pendingRoute = route;
    if (!_routeController.isClosed) {
      _routeController.add(route);
    }
  }

  Future<void> _registerWindowsDeviceToken({
    required SupabaseClient supabase,
    required String userId,
  }) async {
    try {
      final channelUri = await WindowsPushService.requestChannelUri();
      if (channelUri == null || channelUri.isEmpty) {
        debugPrint(
          '[Notifications] WNS registration skipped: configure WNS_AAD_REMOTE_ID and the Windows App SDK bridge.',
        );
        return;
      }
      await supabase.rpc(
        'register_push_device_token',
        params: {
          'p_provider': 'wns',
          'p_token': channelUri,
          'p_platform': _platformLabel,
          'p_device_label': _platformLabel,
          'p_expires_at': null,
        },
      );
    } catch (error) {
      debugPrint('[Notifications] WNS registration skipped: $error');
    }
  }

  String get _platformLabel {
    if (kIsWeb) {
      return 'web';
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'fuchsia',
    };
  }

  bool get _supportsFcm {
    if (kIsWeb) {
      return true;
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.macOS => true,
      _ => false,
    };
  }

  void _ensureTokenRefreshSubscription() {
    _tokenSubscription ??= FirebaseMessaging.instance.onTokenRefresh.listen(
      (token) async {
        final controller = _registrationController;
        final scope = _registrationScope;
        if (controller == null || scope == null || token.isEmpty) return;
        await controller.registerRefreshedToken(scope, token);
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[Notifications] FCM token refresh failed.');
      },
    );
  }

  ({
    NotificationRegistrationController controller,
    NotificationRegistrationScope scope,
  })?
  _registrationFor(SupabaseClient client) {
    final user = client.auth.currentUser;
    if (user == null) return null;
    final scope = _scopeFor(client, user.id);
    if (_registrationScope?.accountKey == scope.accountKey &&
        _registrationController != null) {
      return (controller: _registrationController!, scope: scope);
    }

    _clearRegistrationController();
    final controller = NotificationRegistrationController(
      provider: _FirebasePushTokenProvider(
        isSupported: () => _supportsFcm && _firebaseReady,
        token: _firebaseToken,
        canShowNotifications: _canShowNotifications,
      ),
      registry: _registryFor(client),
      preferences: SharedPreferencesNotificationPreferenceStore(),
    );
    void forwardStatus() {
      _publishRegistrationStatus(controller.status.value);
    }

    controller.status.addListener(forwardStatus);
    _registrationController = controller;
    _registrationScope = scope;
    _registrationListener = forwardStatus;
    forwardStatus();
    return (controller: controller, scope: scope);
  }

  RpcPushTokenRegistry _registryFor(SupabaseClient client) {
    return RpcPushTokenRegistry(
      currentUserId: () => client.auth.currentUser?.id,
      invoke: (function, params) => client.rpc(function, params: params),
    );
  }

  NotificationRegistrationScope _scopeFor(
    SupabaseClient client,
    String userId,
  ) {
    final uri = Uri.tryParse(SupabaseConfig.url);
    final backendOrigin = uri?.hasScheme == true && uri?.host.isNotEmpty == true
        ? uri!.origin
        : 'supabase';
    return NotificationRegistrationScope(
      backendOrigin: backendOrigin,
      userId: userId,
      platform: _platformLabel,
    );
  }

  Future<String?> _firebaseToken() {
    return FirebaseMessaging.instance.getToken(
      vapidKey: kIsWeb && ChatFirebaseOptions.webVapidKey.isNotEmpty
          ? ChatFirebaseOptions.webVapidKey
          : null,
      serviceWorkerScriptPath: kIsWeb
          ? ChatFirebaseOptions.webMessagingServiceWorkerPath
          : null,
    );
  }

  Future<bool> _canShowNotifications() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    final android = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) {
      return true;
    }
    try {
      if (await android.areNotificationsEnabled() == false) {
        debugPrint('[Notifications] Android app notifications are disabled.');
        return false;
      }
      final channels = await android.getNotificationChannels();
      for (final channel in channels ?? const <AndroidNotificationChannel>[]) {
        if (channel.id == _androidChannel.id &&
            channel.importance == Importance.none) {
          debugPrint(
            '[Notifications] Android chat notification channel is disabled.',
          );
          return false;
        }
      }
    } catch (error) {
      debugPrint('[Notifications] Android notification state unavailable.');
    }
    return true;
  }

  void _clearRegistrationController() {
    final controller = _registrationController;
    final listener = _registrationListener;
    if (controller != null && listener != null) {
      controller.status.removeListener(listener);
    }
    controller?.dispose();
    _registrationController = null;
    _registrationScope = null;
    _registrationListener = null;
    _lastLoggedRegistrationState = null;
    registrationStatus.value = const NotificationRegistrationStatus.disabled();
  }

  void _publishRegistrationStatus(NotificationRegistrationStatus status) {
    registrationStatus.value = status;
    if (_lastLoggedRegistrationState == status.state) return;
    _lastLoggedRegistrationState = status.state;
    final detail = switch (status.state) {
      NotificationRegistrationState.disabled =>
        'disabled; enable it from Profile',
      NotificationRegistrationState.enabling => 'requesting permission',
      NotificationRegistrationState.enabled => 'enabled',
      NotificationRegistrationState.denied =>
        'blocked in device or browser settings',
      NotificationRegistrationState.unsupported => 'unsupported',
      NotificationRegistrationState.failed => 'failed; retry from Profile',
    };
    debugPrint(
      '[Notifications] Registration state for $_platformLabel: $detail.',
    );
  }
}

class _FirebasePushTokenProvider implements PushTokenProvider {
  const _FirebasePushTokenProvider({
    required this._isSupported,
    required this._token,
    required this._canShowNotifications,
  });

  final bool Function() _isSupported;
  final Future<String?> Function() _token;
  final Future<bool> Function() _canShowNotifications;

  @override
  bool get isSupported => _isSupported();

  @override
  Future<String?> getToken() => _token();

  @override
  Future<PushPermissionStatus> permissionStatus() async {
    if (!isSupported) return PushPermissionStatus.unsupported;
    final settings = await FirebaseMessaging.instance.getNotificationSettings();
    return _effectivePermission(settings.authorizationStatus);
  }

  @override
  Future<PushPermissionStatus> requestPermission() async {
    if (!isSupported) return PushPermissionStatus.unsupported;
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    return _effectivePermission(settings.authorizationStatus);
  }

  Future<PushPermissionStatus> _effectivePermission(
    AuthorizationStatus status,
  ) async {
    final permission = _permission(status);
    if ((permission == PushPermissionStatus.authorized ||
            permission == PushPermissionStatus.provisional) &&
        !await _canShowNotifications()) {
      return PushPermissionStatus.denied;
    }
    return permission;
  }

  PushPermissionStatus _permission(AuthorizationStatus status) {
    return switch (status) {
      AuthorizationStatus.authorized => PushPermissionStatus.authorized,
      AuthorizationStatus.provisional => PushPermissionStatus.provisional,
      AuthorizationStatus.denied => PushPermissionStatus.denied,
      AuthorizationStatus.notDetermined => PushPermissionStatus.notDetermined,
    };
  }
}
