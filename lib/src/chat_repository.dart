import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_models.dart';

class ChatRepository {
  const ChatRepository({this.client});

  final SupabaseClient? client;

  bool get isConnected => client != null;

  List<ChatThread> get threads => ChatSeed.threads;

  User? get _currentUser => client?.auth.currentUser;

  String get localUserId => _currentUser?.id ?? ChatSeed.localUserId;

  String get localSenderName {
    final user = _currentUser;
    final metadata = user?.userMetadata;
    final metadataName =
        metadata?['display_name'] ??
        metadata?['full_name'] ??
        metadata?['name'];
    final displayName = metadataName?.toString().trim();

    if (displayName != null && displayName.isNotEmpty) {
      return displayName;
    }

    final emailName = user?.email?.split('@').first.trim();
    if (emailName != null && emailName.isNotEmpty) {
      return emailName;
    }

    final phone = user?.phone?.trim();
    if (phone != null && phone.isNotEmpty) {
      return phone;
    }

    return 'You';
  }

  Stream<List<ChatMessage>> watchMessages(String threadId) {
    final supabase = client;
    if (supabase == null) {
      return Stream.value(ChatSeed.messagesFor(threadId));
    }
    if (supabase.auth.currentUser == null) {
      return Stream.value(const []);
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

    final user = supabase.auth.currentUser;
    if (user == null) {
      throw const AuthException('Sign in before sending messages.');
    }

    await supabase.from('messages').insert({
      'thread_id': threadId,
      'sender_id': user.id,
      'sender_name': localSenderName,
      'body': trimmed,
    });
  }
}
