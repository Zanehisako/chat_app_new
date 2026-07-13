import 'package:chat_app/src/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses group-call push routes without breaking message routes', () {
    final route = NotificationRoute.fromData({
      'type': 'group_call',
      'conversation_id': 'conversation-1',
      'call_id': 'call-1',
    });

    expect(route, isNotNull);
    expect(route!.kind, 'group_call');
    expect(route.callId, 'call-1');
    expect(route.conversationId, 'conversation-1');
  });

  test('legacy notification data defaults to a message route', () {
    final route = NotificationRoute.fromData({
      'conversation_id': 'conversation-1',
      'message_id': 'message-1',
    });

    expect(route!.kind, 'message');
    expect(route.callId, isNull);
    expect(route.messageId, 'message-1');
  });
}
