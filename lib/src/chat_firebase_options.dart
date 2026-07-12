import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

class ChatFirebaseOptions {
  ChatFirebaseOptions._();

  static const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const _appId = String.fromEnvironment('FIREBASE_APP_ID');
  static const _messagingSenderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
    defaultValue: '985458829467',
  );
  static const _projectId = String.fromEnvironment(
    'FIREBASE_PROJECT_ID',
    defaultValue: 'chat-app-92f45',
  );
  static const _authDomain = String.fromEnvironment(
    'FIREBASE_AUTH_DOMAIN',
    defaultValue: 'chat-app-92f45.firebaseapp.com',
  );
  static const _storageBucket = String.fromEnvironment(
    'FIREBASE_STORAGE_BUCKET',
    defaultValue: 'chat-app-92f45.firebasestorage.app',
  );
  static const _measurementId = String.fromEnvironment(
    'FIREBASE_MEASUREMENT_ID',
    defaultValue: 'G-SJT2TBNRV7',
  );
  static const _androidClientId = String.fromEnvironment(
    'FIREBASE_ANDROID_CLIENT_ID',
  );
  static const _iosClientId = String.fromEnvironment('FIREBASE_IOS_CLIENT_ID');
  static const _iosBundleId = String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID');
  static const _appGroupId = String.fromEnvironment('FIREBASE_APP_GROUP_ID');
  static const webVapidKey = String.fromEnvironment(
    'FCM_WEB_VAPID_KEY',
    defaultValue:
        'BCqbK-8ngYY6rBrLstjbv11kbxm_15_1KyDgCZCrE2Ix5i9RxsEKhi1LnI3j4JCgFug1b3SUh0r-dcnh6PG3pNo',
  );
  static const webMessagingServiceWorkerPath = '/firebase-messaging-sw.js';

  static const _androidApiKey = String.fromEnvironment(
    'FIREBASE_ANDROID_API_KEY',
  );
  static const _androidAppId = String.fromEnvironment(
    'FIREBASE_ANDROID_APP_ID',
  );
  static const _iosApiKey = String.fromEnvironment('FIREBASE_IOS_API_KEY');
  static const _iosAppId = String.fromEnvironment('FIREBASE_IOS_APP_ID');
  static const _macosApiKey = String.fromEnvironment('FIREBASE_MACOS_API_KEY');
  static const _macosAppId = String.fromEnvironment('FIREBASE_MACOS_APP_ID');
  static const _macosBundleId = String.fromEnvironment(
    'FIREBASE_MACOS_BUNDLE_ID',
  );
  static const _webApiKey = String.fromEnvironment(
    'FIREBASE_WEB_API_KEY',
    defaultValue: 'AIzaSyAnChOTYevX3IrdNmB5DeMXKD-jDlodYDA',
  );
  static const _webAppId = String.fromEnvironment(
    'FIREBASE_WEB_APP_ID',
    defaultValue: '1:985458829467:web:5bb19669149181af037e3e',
  );

  static FirebaseOptions? get currentPlatform {
    final platform = _platformValues();
    if (platform.apiKey.isEmpty ||
        platform.appId.isEmpty ||
        _messagingSenderId.isEmpty ||
        _projectId.isEmpty) {
      return null;
    }

    return FirebaseOptions(
      apiKey: platform.apiKey,
      appId: platform.appId,
      messagingSenderId: _messagingSenderId,
      projectId: _projectId,
      authDomain: _authDomain,
      storageBucket: _storageBucket,
      measurementId: _measurementId,
      androidClientId: _androidClientId,
      iosClientId: _iosClientId,
      iosBundleId: platform.iosBundleId,
      appGroupId: _appGroupId,
    );
  }

  static _FirebasePlatformValues _platformValues() {
    if (kIsWeb) {
      return _FirebasePlatformValues(
        apiKey: _first(_webApiKey, _apiKey),
        appId: _first(_webAppId, _appId),
        iosBundleId: _iosBundleId,
      );
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => _FirebasePlatformValues(
        apiKey: _first(_androidApiKey, _apiKey),
        appId: _first(_androidAppId, _appId),
        iosBundleId: _iosBundleId,
      ),
      TargetPlatform.iOS => _FirebasePlatformValues(
        apiKey: _first(_iosApiKey, _apiKey),
        appId: _first(_iosAppId, _appId),
        iosBundleId: _iosBundleId,
      ),
      TargetPlatform.macOS => _FirebasePlatformValues(
        apiKey: _first(_macosApiKey, _apiKey),
        appId: _first(_macosAppId, _appId),
        iosBundleId: _first(_macosBundleId, _iosBundleId),
      ),
      _ => _FirebasePlatformValues(
        apiKey: _apiKey,
        appId: _appId,
        iosBundleId: _iosBundleId,
      ),
    };
  }

  static String _first(String primary, String fallback) {
    return primary.isNotEmpty ? primary : fallback;
  }
}

class _FirebasePlatformValues {
  const _FirebasePlatformValues({
    required this.apiKey,
    required this.appId,
    required this.iosBundleId,
  });

  final String apiKey;
  final String appId;
  final String iosBundleId;
}
