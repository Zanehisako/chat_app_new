import 'dart:js_interop';

import 'package:web/web.dart' as web;

class WebNotificationPresenter {
  Future<bool> show({
    required String title,
    required String body,
    required void Function() onClick,
  }) async {
    if (web.Notification.permission != 'granted') {
      return false;
    }
    final notification = web.Notification(
      title,
      web.NotificationOptions(body: body, icon: '/icons/Icon-192.png'),
    );
    notification.onclick = ((web.Event event) {
      event.preventDefault();
      notification.close();
      onClick();
    }).toJS;
    return true;
  }
}
