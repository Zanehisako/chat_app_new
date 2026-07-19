import 'package:chat_app/src/chat_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('encrypted rows never expose server plaintext or media metadata', () {
    final message = ChatMessage.fromSupabase({
      'id': 'encrypted-message',
      'conversation_id': 'conversation-1',
      'sender_id': 'other-user',
      'sender_name': 'Mina',
      'body': 'plaintext must never render',
      'created_at': DateTime.utc(2026, 7, 15).toIso8601String(),
      'message_type': 'image',
      'encryption_version': 1,
      'e2ee_epoch_number': 3,
      'media_bucket': 'chat-media',
      'media_path': 'conversation-1/opaque-object',
      'media_mime_type': 'image/jpeg',
      'media_original_name': 'private-photo.jpg',
    }, localUserId: 'local-user');

    expect(message.encryptionState, ChatMessageEncryptionState.locked);
    expect(message.body, isEmpty);
    expect(message.media, isNull);
    expect(message.actionPreview, 'Encrypted message unavailable');
  });

  test('zero encryption protocol version remains a legacy row', () {
    final message = ChatMessage.fromSupabase({
      'id': 'legacy-message',
      'conversation_id': 'conversation-1',
      'sender_id': 'other-user',
      'sender_name': 'Mina',
      'body': 'Legacy message',
      'created_at': DateTime.utc(2026, 7, 15).toIso8601String(),
      'encryption_version': 0,
    }, localUserId: 'local-user');

    expect(message.encryptionState, ChatMessageEncryptionState.legacy);
    expect(message.body, 'Legacy message');
  });
}
