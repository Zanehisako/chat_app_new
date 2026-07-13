import 'dart:js_interop';

import 'package:web/web.dart' as web;

class WebNotificationPresenter {
  Future<bool> show({
    required String title,
    required String body,
    String? conversationId,
    String? messageId,
    String? type,
    String? callId,
  }) async {
    if (web.Notification.permission != 'granted') {
      return false;
    }
    try {
      final registration = await web.window.navigator.serviceWorker
          .getRegistration()
          .toDart;
      if (registration == null) {
        return false;
      }
      final queryParameters = <String, String>{};
      if (conversationId != null && conversationId.trim().isNotEmpty) {
        queryParameters['conversation'] = conversationId.trim();
      }
      if (type != null && type.trim().isNotEmpty) {
        queryParameters['type'] = type.trim();
      }
      if (callId != null && callId.trim().isNotEmpty) {
        queryParameters['call_id'] = callId.trim();
      }
      final link = Uri.parse(web.window.location.origin)
          .replace(
            queryParameters: queryParameters.isEmpty ? null : queryParameters,
          )
          .toString();
      await registration
          .showNotification(
            title,
            web.NotificationOptions(
              body: body,
              icon: '/icons/Icon-192.png',
              tag: messageId ?? '',
              data: <String, String>{'chatAppLink': link}.jsify(),
            ),
          )
          .toDart;
      return true;
    } catch (_) {
      return false;
    }
  }
}
