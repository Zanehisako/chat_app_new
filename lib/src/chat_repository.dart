import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_models.dart';

class ChatRepository {
  const ChatRepository({this.client});

  final SupabaseClient? client;

  bool get isConnected => client != null;

  List<ChatThread> get threads => ChatSeed.threads;

  String get localUserId =>
      client?.auth.currentUser?.id ?? ChatSeed.localUserId;

  String get localSenderName =>
      client?.auth.currentUser?.email?.split('@').first ?? 'You';

  Stream<List<ChatMessage>> watchMessages(String threadId) {
    final supabase = client;
    if (supabase == null) {
      return Stream.value(ChatSeed.messagesFor(threadId));
    }

    return supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('thread_id', threadId)
        .order('created_at')
        .map(
          (rows) => rows
              .map(
                (row) =>
                    ChatMessage.fromSupabase(row, localUserId: localUserId),
              )
              .toList(),
        );
  }

  Future<void> sendMessage({
    required String threadId,
    required String body,
  }) async {
    final trimmed = body.trim();
    final supabase = client;
    if (trimmed.isEmpty || supabase == null) {
      return;
    }

    await supabase.from('messages').insert({
      'thread_id': threadId,
      'sender_id': localUserId,
      'sender_name': localSenderName,
      'body': trimmed,
    });
  }
}
